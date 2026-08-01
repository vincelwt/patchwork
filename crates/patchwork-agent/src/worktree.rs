//! Task-owned folders and git worktrees.
//!
//! A worktree belongs to a task, not to a run: retrying with another agent or
//! another runtime continues in the same directory, and different tasks run
//! concurrently in different directories.

use std::path::{Path, PathBuf};
use std::process::Stdio;

use anyhow::{anyhow, bail, Context, Result};
use patchwork_core::host::WorktreeSpec;
use tokio::process::Command;

#[derive(Debug, Clone)]
pub struct PreparedWorktree {
    pub path: String,
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

pub async fn prepare(spec: &WorktreeSpec, task_key: &str) -> Result<PreparedWorktree> {
    match spec {
        WorktreeSpec::None => {
            let path = work_root().join("scratch").join(task_key);
            tokio::fs::create_dir_all(&path).await?;
            Ok(PreparedWorktree {
                path: path.to_string_lossy().to_string(),
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
                branch: current_branch(path).await.unwrap_or_default(),
                base_branch: String::new(),
                is_main_checkout: false,
                created: false,
            })
        }
        WorktreeSpec::New {
            project_path,
            branch,
            base_branch,
        } => new_worktree(project_path, branch, base_branch).await,
    }
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

    Ok(PreparedWorktree {
        path: path_str,
        branch: branch.to_string(),
        base_branch: base,
        is_main_checkout: false,
        created: true,
    })
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
    fn branch_names_are_readable_and_safe() {
        let b = branch_for("PW-14", "Fix the checkout: totals are wrong!");
        assert_eq!(b, "patchwork/pw-14-fix-the-checkout-totals-are-wrong");
        assert_eq!(sanitize(&b), "patchwork-pw-14-fix-the-checkout-totals-are-wrong");
    }

    #[tokio::test]
    async fn scratch_directory_is_created_for_non_code_work() {
        let prepared = prepare(&WorktreeSpec::None, "test-scratch-task")
            .await
            .unwrap();
        assert!(Path::new(&prepared.path).is_dir());
        let _ = tokio::fs::remove_dir_all(&prepared.path).await;
    }
}
