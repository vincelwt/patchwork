//! Task-owned folders and git worktrees.
//!
//! A worktree belongs to a task, not to a run: retrying with another agent or
//! another runtime continues in the same directory, and different tasks run
//! concurrently in different directories.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, SystemTime};

use anyhow::{anyhow, bail, Context, Result};
use patchwork_core::host::WorktreeSpec;
use tokio::process::Command;
use tokio::sync::Mutex;

/// Creation and pruning must not race over the same task folder. Serializing
/// them also means two agents starting together create one worktree.
static WORKTREES: Mutex<()> = Mutex::const_new(());

#[derive(Debug, Clone)]
pub struct PreparedWorktree {
    pub path: String,
    /// The checkout this worktree was cut from, when the host had to fetch it.
    pub cloned_to: Option<String>,
    pub branch: String,
    pub base_branch: String,
    pub is_main_checkout: bool,
    /// True when the directory was created by this call.
    pub created: bool,
}

/// Root for every worktree and scratch folder this machine owns.
pub fn work_root() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".patchwork")
}

/// Remove idle task folders without losing work that has not reached git.
pub async fn prune(in_use: &HashSet<PathBuf>, retention: Duration) -> Result<usize> {
    let _one_at_a_time = WORKTREES.lock().await;
    prune_root(&work_root(), in_use, retention).await
}

async fn prune_root(root: &Path, in_use: &HashSet<PathBuf>, retention: Duration) -> Result<usize> {
    let mut candidates: Vec<_> = child_dirs(&root.join("scratch"))
        .await?
        .into_iter()
        .map(|path| (path, false))
        .collect();
    for repo in child_dirs(&root.join("worktrees")).await? {
        candidates.extend(
            child_dirs(&repo)
                .await?
                .into_iter()
                .map(|path| (path, true)),
        );
    }

    let mut removed = 0;
    for (path, is_worktree) in candidates {
        if in_use
            .iter()
            .any(|used| used == &path || used.starts_with(&path))
        {
            continue;
        }
        let path_str = path.to_string_lossy().to_string();
        let git_repo = is_worktree || path.join(".git").exists() || is_git_repo(&path_str).await;
        let mut git_repos = git_repo
            .then_some(path.clone())
            .into_iter()
            .collect::<Vec<_>>();
        if !git_repo {
            let Ok(children) = child_dirs(&path).await else {
                tracing::debug!(path = %path.display(), "could not inspect scratch folder");
                continue;
            };
            // ponytail: task checkouts live directly under scratch. Scan deeper
            // only if a real task launcher introduces another layout.
            for child in children {
                let child_str = child.to_string_lossy();
                if child.join(".git").exists() || is_git_repo(&child_str).await {
                    git_repos.push(child);
                }
            }
        }

        let Ok(mut activity) = most_recent_activity(&path, git_repo).await else {
            tracing::debug!(path = %path.display(), "could not read task folder activity");
            continue;
        };
        let mut readable = true;
        for repo in git_repos.iter().filter(|repo| *repo != &path) {
            match most_recent_activity(repo, true).await {
                Ok(repo_activity) => activity = activity.max(repo_activity),
                Err(err) => {
                    tracing::debug!(?err, path = %repo.display(), "could not read nested worktree activity");
                    readable = false;
                    break;
                }
            }
        }
        if !readable
            || SystemTime::now()
                .duration_since(activity)
                .unwrap_or_default()
                <= retention
        {
            continue;
        }

        let mut clean = true;
        for repo in &git_repos {
            match git(&repo.to_string_lossy(), &["status", "--porcelain"]).await {
                Ok(status) if status.trim().is_empty() => {}
                Ok(_) => {
                    tracing::debug!(path = %repo.display(), "keeping dirty task folder");
                    clean = false;
                    break;
                }
                Err(err) => {
                    tracing::debug!(?err, path = %repo.display(), "could not verify task folder is clean");
                    clean = false;
                    break;
                }
            }
        }
        if !clean {
            continue;
        }

        if is_worktree {
            if let Err(err) = remove_worktree(&path).await {
                tracing::warn!(?err, path = %path.display(), "could not prune task worktree");
                continue;
            }
        } else {
            let mut failed = false;
            for repo in git_repos.iter().filter(|repo| *repo != &path) {
                if let Err(err) = remove_worktree(repo).await {
                    tracing::warn!(?err, path = %repo.display(), "could not prune nested task worktree");
                    failed = true;
                    break;
                }
            }
            if failed {
                continue;
            }
            if let Err(err) = tokio::fs::remove_dir_all(&path).await {
                tracing::warn!(?err, path = %path.display(), "could not prune scratch folder");
                continue;
            }
        }
        removed += 1;
        tracing::info!(path = %path.display(), "pruned idle task folder");
    }
    Ok(removed)
}

async fn child_dirs(path: &Path) -> Result<Vec<PathBuf>> {
    let mut children = Vec::new();
    let mut entries = match tokio::fs::read_dir(path).await {
        Ok(entries) => entries,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(children),
        Err(err) => return Err(err.into()),
    };
    while let Some(entry) = entries.next_entry().await? {
        if entry.file_type().await?.is_dir() {
            children.push(entry.path());
        }
    }
    Ok(children)
}

async fn most_recent_activity(path: &Path, git_worktree: bool) -> Result<SystemTime> {
    let mut latest = tokio::fs::metadata(path).await?.modified()?;
    if git_worktree {
        // Deep edits do not touch the directory itself. Git updates its index
        // and HEAD reflog for normal status, staging and commit activity, so
        // these two cheap stats are a useful approximation without a tree walk.
        let path_str = path.to_string_lossy();
        let paths = git(
            &path_str,
            &[
                "rev-parse",
                "--git-path",
                "index",
                "--git-path",
                "logs/HEAD",
            ],
        )
        .await?;
        for git_path in paths.lines().map(PathBuf::from) {
            let git_path = if git_path.is_absolute() {
                git_path
            } else {
                path.join(git_path)
            };
            if let Ok(modified) = tokio::fs::metadata(git_path)
                .await
                .and_then(|m| m.modified())
            {
                latest = latest.max(modified);
            }
        }
    }
    Ok(latest)
}

async fn remove_worktree(path: &Path) -> Result<()> {
    let path_str = path.to_string_lossy().to_string();
    let checkout = git(&path_str, &["worktree", "list", "--porcelain"])
        .await
        .ok()
        .and_then(|list| {
            list.lines()
                .find_map(|line| line.strip_prefix("worktree ").map(str::to_string))
        });
    if let Some(checkout) = &checkout {
        if git(checkout, &["worktree", "remove", "--force", &path_str])
            .await
            .is_ok()
        {
            return Ok(());
        }
    }

    tokio::fs::remove_dir_all(path).await?;
    if let Some(checkout) = checkout {
        let _ = git(&checkout, &["worktree", "prune"]).await;
    }
    Ok(())
}

pub async fn prepare(spec: &WorktreeSpec, task_key: &str) -> Result<PreparedWorktree> {
    let _one_at_a_time = WORKTREES.lock().await;
    match spec {
        WorktreeSpec::None => {
            let path = work_root().join("scratch").join(task_key);
            tokio::fs::create_dir_all(&path).await?;
            Ok(PreparedWorktree {
                path: path.to_string_lossy().to_string(),
                cloned_to: None,
                branch: String::new(),
                base_branch: String::new(),
                is_main_checkout: false,
                created: true,
            })
        }
        WorktreeSpec::MainCheckout { project_path } => {
            if !Path::new(project_path).exists() {
                bail!("project path does not exist on this machine: {project_path}");
            }
            Ok(PreparedWorktree {
                path: project_path.clone(),
                cloned_to: None,
                branch: current_branch(project_path).await.unwrap_or_default(),
                base_branch: String::new(),
                is_main_checkout: true,
                created: false,
            })
        }
        WorktreeSpec::Existing { path } => {
            if !Path::new(path).exists() {
                bail!("worktree no longer exists on this machine: {path}");
            }
            Ok(PreparedWorktree {
                path: path.clone(),
                cloned_to: None,
                branch: current_branch(path).await.unwrap_or_default(),
                base_branch: String::new(),
                is_main_checkout: false,
                created: false,
            })
        }
        WorktreeSpec::New {
            project_path,
            repo_url,
            project_name,
            branch,
            base_branch,
        } => {
            let (checkout, cloned) = match project_path {
                Some(path) if Path::new(path).exists() => (path.clone(), None),
                _ => {
                    let path = clone_project(repo_url.as_deref(), project_name).await?;
                    (path.clone(), Some(path))
                }
            };
            let mut prepared = new_worktree(&checkout, branch, base_branch).await?;
            prepared.cloned_to = cloned;
            Ok(prepared)
        }
    }
}

/// Where this machine keeps the checkouts it made for itself.
pub fn projects_root() -> PathBuf {
    work_root().join("projects")
}

/// A checkout is something a machine can fetch. Cloning here is what makes a
/// project usable on a relay nobody wants to ssh into.
///
/// The URL is used exactly as given: an `ssh://` or `git@` remote clones with
/// the machine's own key, which is the answer for a private repo on a server.
/// For `https://github.com/...`, `gh` is preferred when it is signed in, since
/// it carries the credentials the same machine already uses to open pull
/// requests.
async fn clone_project(repo_url: Option<&str>, project_name: &str) -> Result<String> {
    let url = repo_url.filter(|u| !u.trim().is_empty()).ok_or_else(|| {
        anyhow!(
            "`{project_name}` is not on this machine and has no repository to clone. \
Add a repository URL to the project, or set its folder on this machine."
        )
    })?;

    let dir = projects_root().join(sanitize(&repo_slug(url, project_name)));
    if dir.exists() {
        return Ok(dir.to_string_lossy().to_string());
    }
    tokio::fs::create_dir_all(projects_root()).await?;
    let target = dir.to_string_lossy().to_string();

    let use_gh = url.contains("github.com")
        && !url.starts_with("git@")
        && crate::detect::gh_is_authenticated().await;
    let result = if use_gh {
        run("gh", &["repo", "clone", url, &target]).await
    } else {
        run("git", &["clone", url, &target]).await
    };

    if let Err(err) = result {
        // The directory may exist half-made; a retry should start clean.
        let _ = tokio::fs::remove_dir_all(&dir).await;
        return Err(err.context(clone_advice(url)));
    }
    Ok(target)
}

/// Why a clone of a private repository fails, and the three ways out.
fn clone_advice(url: &str) -> String {
    if url.starts_with("git@") || url.starts_with("ssh://") {
        format!("could not clone {url}: this machine's SSH key has no access to it")
    } else {
        format!(
            "could not clone {url}: this machine has no credentials for it. \
Sign in with `gh auth login` there, give it a GH_TOKEN, or use an SSH URL with a deploy key."
        )
    }
}

/// `git@github.com:acme/app.git` and `https://github.com/acme/app` are both
/// `acme-app`, so one machine keeps one copy however the URL was written.
fn repo_slug(url: &str, fallback: &str) -> String {
    let trimmed = url.trim_end_matches('/').trim_end_matches(".git");
    let tail: Vec<&str> = trimmed
        .rsplit(['/', ':'])
        .take(2)
        .filter(|part| !part.is_empty())
        .collect();
    match tail.len() {
        2 => format!("{}-{}", tail[1], tail[0]),
        1 => tail[0].to_string(),
        _ => fallback.to_string(),
    }
}

async fn run(program: &str, args: &[&str]) -> Result<()> {
    let out = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .output()
        .await
        .with_context(|| format!("failed to run {program}"))?;
    if !out.status.success() {
        return Err(anyhow!(
            "{program} {}: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(())
}

async fn new_worktree(
    project_path: &str,
    branch: &str,
    base_branch: &str,
) -> Result<PreparedWorktree> {
    if !Path::new(project_path).exists() {
        bail!("project path does not exist on this machine: {project_path}");
    }
    if !is_git_repo(project_path).await {
        // A plain folder project: work directly in it.
        return Ok(PreparedWorktree {
            path: project_path.to_string(),
            cloned_to: None,
            branch: String::new(),
            base_branch: String::new(),
            is_main_checkout: true,
            created: false,
        });
    }

    let repo_name = Path::new(project_path)
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| "project".into());
    let dir = work_root()
        .join("worktrees")
        .join(&repo_name)
        .join(sanitize(branch));

    if dir.exists() {
        return Ok(PreparedWorktree {
            path: dir.to_string_lossy().to_string(),
            cloned_to: None,
            branch: branch.to_string(),
            base_branch: base_branch.to_string(),
            is_main_checkout: false,
            created: false,
        });
    }
    tokio::fs::create_dir_all(dir.parent().unwrap()).await?;

    let base = if base_branch.is_empty() {
        current_branch(project_path)
            .await
            .unwrap_or_else(|| "HEAD".into())
    } else {
        base_branch.to_string()
    };

    let path_str = dir.to_string_lossy().to_string();
    let branch_exists = git(project_path, &["rev-parse", "--verify", branch])
        .await
        .is_ok();

    let args: Vec<&str> = if branch_exists {
        vec!["worktree", "add", &path_str, branch]
    } else {
        vec!["worktree", "add", "-b", branch, &path_str, &base]
    };

    git(project_path, &args)
        .await
        .with_context(|| format!("git worktree add failed for {branch}"))?;
    carry_untracked_config(project_path, &path_str).await;

    Ok(PreparedWorktree {
        path: path_str,
        cloned_to: None,
        branch: branch.to_string(),
        base_branch: base,
        is_main_checkout: false,
        created: true,
    })
}

/// A fresh worktree has only what git tracks, so the `.env` the project needs
/// to run is exactly the file it does not get. Copy those across from the
/// checkout it was cut from: local file to local file, nothing leaves the
/// machine, and a dev server started by an agent behaves like one started by
/// hand.
///
/// ponytail: the checkout root only. A monorepo with `apps/web/.env` needs a
/// per-project list of paths; add one when that is somebody's actual repo,
/// not before, because walking a tree for `.env*` finds them in
/// `node_modules` too.
async fn carry_untracked_config(checkout: &str, worktree: &str) {
    let Ok(mut entries) = tokio::fs::read_dir(checkout).await else {
        return;
    };
    while let Ok(Some(entry)) = entries.next_entry().await {
        let name = entry.file_name().to_string_lossy().to_string();
        if !name.starts_with(".env") {
            continue;
        }
        if entry
            .file_type()
            .await
            .map(|t| !t.is_file())
            .unwrap_or(true)
        {
            continue;
        }
        let target = Path::new(worktree).join(&name);
        // Never over a tracked file: `.env.example` belongs to the repo.
        if target.exists() {
            continue;
        }
        if let Err(err) = tokio::fs::copy(entry.path(), &target).await {
            tracing::warn!(?err, %name, "could not carry a config file into the worktree");
        }
    }
}

pub async fn is_git_repo(path: &str) -> bool {
    git(path, &["rev-parse", "--is-inside-work-tree"])
        .await
        .map(|s| s.trim() == "true")
        .unwrap_or(false)
}

pub async fn current_branch(path: &str) -> Option<String> {
    git(path, &["rev-parse", "--abbrev-ref", "HEAD"])
        .await
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty() && s != "HEAD")
}

/// A compact summary of what changed in the worktree, used for review handoff.
pub async fn status_summary(path: &str) -> Option<String> {
    let out = git(path, &["status", "--short"]).await.ok()?;
    let lines: Vec<&str> = out.lines().filter(|l| !l.trim().is_empty()).collect();
    if lines.is_empty() {
        return None;
    }
    let shown: Vec<&str> = lines.iter().take(12).copied().collect();
    let mut s = shown.join("\n");
    if lines.len() > shown.len() {
        s.push_str(&format!("\n… and {} more", lines.len() - shown.len()));
    }
    Some(s)
}

pub async fn git(cwd: &str, args: &[&str]) -> Result<String> {
    let out = Command::new("git")
        .args(args)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .output()
        .await
        .context("failed to run git")?;
    if !out.status.success() {
        return Err(anyhow!(
            "git {}: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).to_string())
}

/// Branch names are used as directory names; keep them filesystem-safe.
pub fn sanitize(name: &str) -> String {
    name.replace(['/', '\\', ' ', ':'], "-")
}

/// The branch a new task worktree gets: `patchwork/<task-key>-<slug>`.
pub fn branch_for(task_key: &str, title: &str) -> String {
    let slug = patchwork_core::ids::slugify(title);
    let slug: String = slug.chars().take(40).collect();
    let slug = slug.trim_end_matches('-');
    format!("patchwork/{}-{}", task_key.to_lowercase(), slug)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_machine_keeps_one_copy_however_the_url_was_written() {
        assert_eq!(repo_slug("https://github.com/acme/app", "x"), "acme-app");
        assert_eq!(
            repo_slug("https://github.com/acme/app.git", "x"),
            "acme-app"
        );
        assert_eq!(repo_slug("git@github.com:acme/app.git", "x"), "acme-app");
        assert_eq!(repo_slug("ssh://git@host/acme/app/", "x"), "acme-app");
        assert_eq!(repo_slug("", "fallback"), "fallback");
    }

    #[test]
    fn branch_names_are_readable_and_safe() {
        let b = branch_for("PW-14", "Fix the checkout: totals are wrong!");
        assert_eq!(b, "patchwork/pw-14-fix-the-checkout-totals-are-wrong");
        assert_eq!(
            sanitize(&b),
            "patchwork-pw-14-fix-the-checkout-totals-are-wrong"
        );
    }

    #[tokio::test]
    async fn scratch_directory_is_created_for_non_code_work() {
        let prepared = prepare(&WorktreeSpec::None, "test-scratch-task")
            .await
            .unwrap();
        assert!(Path::new(&prepared.path).is_dir());
        let _ = tokio::fs::remove_dir_all(&prepared.path).await;
    }

    async fn pruning_fixture(name: &str, worktree_path: &str) -> (PathBuf, PathBuf) {
        let root =
            std::env::temp_dir().join(format!("patchwork-prune-{name}-{}", uuid::Uuid::new_v4()));
        let checkout = root.join("checkout");
        let worktree = root.join(worktree_path);
        tokio::fs::create_dir_all(&checkout).await.unwrap();
        git(checkout.to_str().unwrap(), &["init", "-b", "main"])
            .await
            .unwrap();
        git(
            checkout.to_str().unwrap(),
            &["config", "user.email", "test@example.com"],
        )
        .await
        .unwrap();
        git(
            checkout.to_str().unwrap(),
            &["config", "user.name", "Patchwork Test"],
        )
        .await
        .unwrap();
        tokio::fs::write(checkout.join("tracked.txt"), "tracked")
            .await
            .unwrap();
        git(checkout.to_str().unwrap(), &["add", "."])
            .await
            .unwrap();
        git(checkout.to_str().unwrap(), &["commit", "-m", "initial"])
            .await
            .unwrap();
        tokio::fs::create_dir_all(worktree.parent().unwrap())
            .await
            .unwrap();
        git(
            checkout.to_str().unwrap(),
            &["worktree", "add", "-b", name, worktree.to_str().unwrap()],
        )
        .await
        .unwrap();
        (root, worktree)
    }

    fn make_path_old(path: &Path) {
        let old = SystemTime::now() - Duration::from_secs(3 * 24 * 60 * 60);
        std::fs::File::open(path)
            .unwrap()
            .set_times(std::fs::FileTimes::new().set_modified(old))
            .unwrap();
    }

    async fn make_old(path: &Path) {
        let path_str = path.to_string_lossy();
        let git_paths = git(
            &path_str,
            &[
                "rev-parse",
                "--git-path",
                "index",
                "--git-path",
                "logs/HEAD",
            ],
        )
        .await
        .unwrap();
        for target in
            std::iter::once(path.to_path_buf()).chain(git_paths.lines().map(PathBuf::from))
        {
            make_path_old(&target);
        }
    }

    #[tokio::test]
    async fn clean_old_worktree_is_pruned() {
        let (root, worktree) = pruning_fixture("clean-old", "managed/worktrees/repo/task").await;
        make_old(&worktree).await;
        let removed = prune_root(
            &root.join("managed"),
            &HashSet::new(),
            Duration::from_secs(2 * 24 * 60 * 60),
        )
        .await
        .unwrap();
        assert_eq!(removed, 1);
        assert!(!worktree.exists());
        let _ = tokio::fs::remove_dir_all(root).await;
    }

    #[tokio::test]
    async fn dirty_old_worktree_is_kept() {
        let (root, worktree) = pruning_fixture("dirty-old", "managed/worktrees/repo/task").await;
        tokio::fs::write(worktree.join("untracked.txt"), "keep me")
            .await
            .unwrap();
        make_old(&worktree).await;
        let removed = prune_root(
            &root.join("managed"),
            &HashSet::new(),
            Duration::from_secs(2 * 24 * 60 * 60),
        )
        .await
        .unwrap();
        assert_eq!(removed, 0);
        assert!(worktree.exists());
        let _ = tokio::fs::remove_dir_all(root).await;
    }

    #[tokio::test]
    async fn fresh_clean_worktree_is_kept() {
        let (root, worktree) = pruning_fixture("fresh-clean", "managed/worktrees/repo/task").await;
        let removed = prune_root(
            &root.join("managed"),
            &HashSet::new(),
            Duration::from_secs(2 * 24 * 60 * 60),
        )
        .await
        .unwrap();
        assert_eq!(removed, 0);
        assert!(worktree.exists());
        let _ = tokio::fs::remove_dir_all(root).await;
    }

    #[tokio::test]
    async fn scratch_with_dirty_nested_worktree_is_kept() {
        let (root, worktree) = pruning_fixture("dirty-nested", "managed/scratch/task/repo").await;
        tokio::fs::write(worktree.join("untracked.txt"), "keep me")
            .await
            .unwrap();
        make_old(&worktree).await;
        make_path_old(&root.join("managed/scratch/task"));
        let removed = prune_root(
            &root.join("managed"),
            &HashSet::new(),
            Duration::from_secs(2 * 24 * 60 * 60),
        )
        .await
        .unwrap();
        assert_eq!(removed, 0);
        assert!(worktree.exists());
        let _ = tokio::fs::remove_dir_all(root).await;
    }
}
