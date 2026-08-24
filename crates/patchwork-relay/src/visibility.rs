use anyhow::Result;
use patchwork_core::events::{Envelope, Event};
use patchwork_core::models::{Automation, AutomationTrigger, ChannelKind};

use crate::store::Store;

pub fn channel(store: &Store, member_id: &str, channel_id: &str) -> Result<bool> {
    let Some(channel) = store.channel(channel_id)? else {
        return Ok(false);
    };
    Ok(channel.kind != ChannelKind::Dm || channel.member_ids.iter().any(|id| id == member_id))
}

pub fn automation(store: &Store, member_id: &str, automation: &Automation) -> Result<bool> {
    let mut channel_ids = [
        automation.context_channel_id.as_deref(),
        automation.report_channel_id.as_deref(),
        None,
    ];
    if let AutomationTrigger::Message { channel_id, .. } = &automation.trigger {
        channel_ids[2] = Some(channel_id.as_str());
    }
    for channel_id in channel_ids.into_iter().flatten() {
        if !channel(store, member_id, channel_id)? {
            return Ok(false);
        }
    }
    Ok(true)
}

pub fn event(store: &Store, member_id: &str, envelope: &Envelope) -> bool {
    event_result(store, member_id, &envelope.event).unwrap_or(false)
}

fn event_result(store: &Store, member_id: &str, event: &Event) -> Result<bool> {
    Ok(match event {
        Event::MessageCreated { message } | Event::MessageUpdated { message } => {
            channel(store, member_id, &message.channel_id)?
        }
        Event::MessageDeleted { channel_id, .. } | Event::Typing { channel_id, .. } => {
            channel(store, member_id, channel_id)?
        }
        Event::ChannelCreated { channel: item } | Event::ChannelUpdated { channel: item } => {
            item.kind != ChannelKind::Dm || item.member_ids.iter().any(|id| id == member_id)
        }
        // The row is already gone, so its old membership cannot be recovered.
        // The opaque id carries no message or participant data.
        Event::ChannelDeleted { .. } => true,
        Event::RunUpdated { run } => channel(store, member_id, &run.channel_id)?,
        Event::RunEventAppended { event } => store
            .run(&event.run_id)?
            .is_some_and(|run| channel(store, member_id, &run.channel_id).unwrap_or(false)),
        Event::QuestionUpdated { question } => channel(store, member_id, &question.channel_id)?,
        Event::InboxItemCreated { item } | Event::InboxItemUpdated { item } => {
            item.member_id == member_id
        }
        Event::AutomationUpdated { automation: item } => automation(store, member_id, item)?,
        Event::AutomationRunUpdated { run } => store
            .automation(&run.automation_id)?
            .is_some_and(|item| automation(store, member_id, &item).unwrap_or(false)),
        _ => true,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use patchwork_core::models::{Channel, Member, MemberKind, Message, MessageKind, Presence};

    fn member(id: &str) -> Member {
        Member {
            id: id.into(),
            kind: MemberKind::Human,
            handle: id.into(),
            display_name: id.into(),
            email: None,
            avatar: None,
            is_admin: false,
            created_at: 1,
            agent: None,
            presence: Presence::Offline,
        }
    }

    #[test]
    fn direct_message_events_only_reach_participants() {
        let path = std::env::temp_dir().join(format!(
            "patchwork-visibility-{}.sqlite",
            patchwork_core::new_id()
        ));
        let store = Store::open(&path).unwrap();
        store.insert_member(&member("inside")).unwrap();
        store.insert_member(&member("outside")).unwrap();
        store
            .insert_channel(&Channel {
                id: "dm".into(),
                kind: ChannelKind::Dm,
                section_id: None,
                slug: String::new(),
                name: "Private".into(),
                topic: String::new(),
                position: 0.0,
                created_at: 1,
                member_ids: vec!["inside".into()],
                task_id: None,
                last_message_at: 1,
            })
            .unwrap();
        let envelope = Envelope {
            seq: 1,
            at: 1,
            event: Event::MessageCreated {
                message: Message {
                    id: "message".into(),
                    channel_id: "dm".into(),
                    author_id: "inside".into(),
                    kind: MessageKind::Text,
                    body: "secret".into(),
                    card: None,
                    suggestions: Vec::new(),
                    parent_id: None,
                    reply_to_id: None,
                    reply_to: None,
                    reply_count: 0,
                    last_reply_at: 0,
                    run_id: None,
                    task_id: None,
                    mentions: Vec::new(),
                    attachments: Vec::new(),
                    reactions: Vec::new(),
                    created_at: 1,
                    edited_at: None,
                },
            },
        };

        assert!(event(&store, "inside", &envelope));
        assert!(!event(&store, "outside", &envelope));
        drop(store);
        let _ = std::fs::remove_file(path);
    }
}
