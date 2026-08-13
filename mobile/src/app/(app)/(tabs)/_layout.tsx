import { NativeTabs } from "expo-router/unstable-native-tabs";

import type { SFSymbol } from "sf-symbols-typescript";

import { unreadInboxCount } from "@client/inbox";
import { workspaceSymbol } from "@/lib/paired";
import { usePairedSession } from "@/lib/session";
import { useWorkspace } from "@/lib/store";
import { useTheme } from "@/lib/theme";

export default function TabLayout() {
  const theme = useTheme();
  const bootstrap = useWorkspace().bootstrap;
  const unread = unreadInboxCount(bootstrap?.inbox ?? []);
  const { session } = usePairedSession();
  // Which workspace is on screen rides on the More tab, the way a settings tab
  // carries the current account, instead of taking a header row on every tab.
  const workspace = workspaceSymbol(session && bootstrap ? { ...session, name: bootstrap.workspace.name } : session) as {
    default: SFSymbol;
    selected: SFSymbol;
  };

  return (
    <NativeTabs
      backBehavior="history"
      minimizeBehavior="onScrollDown"
      // Left adaptable, a big screen turns the tabs into a sidebar that lands on
      // top of the list pane each screen already keeps there.
      sidebarAdaptable={false}
      tintColor={theme.accent}
      backgroundColor={process.env.EXPO_OS === "android" ? theme.raised : undefined}
      indicatorColor={process.env.EXPO_OS === "android" ? theme.accentSoft : undefined}
    >
      <NativeTabs.Trigger name="inbox">
        <NativeTabs.Trigger.Icon sf={{ default: "tray", selected: "tray.fill" }} md="inbox" />
        <NativeTabs.Trigger.Label>Inbox</NativeTabs.Trigger.Label>
        {unread ? <NativeTabs.Trigger.Badge>{String(Math.min(unread, 99))}</NativeTabs.Trigger.Badge> : null}
      </NativeTabs.Trigger>
      <NativeTabs.Trigger name="channels">
        <NativeTabs.Trigger.Icon
          sf={{ default: "bubble.left.and.bubble.right", selected: "bubble.left.and.bubble.right.fill" }}
          md="forum"
        />
        <NativeTabs.Trigger.Label>Chat</NativeTabs.Trigger.Label>
      </NativeTabs.Trigger>
      <NativeTabs.Trigger name="tasks">
        <NativeTabs.Trigger.Icon sf={{ default: "checkmark.circle", selected: "checkmark.circle.fill" }} md="task_alt" />
        <NativeTabs.Trigger.Label>Tasks</NativeTabs.Trigger.Label>
      </NativeTabs.Trigger>
      <NativeTabs.Trigger name="more" role="more">
        <NativeTabs.Trigger.Icon sf={workspace} md="workspaces" />
        <NativeTabs.Trigger.Label>More</NativeTabs.Trigger.Label>
      </NativeTabs.Trigger>
      <NativeTabs.Trigger name="search" role="search">
        <NativeTabs.Trigger.Icon sf="magnifyingglass" md="search" />
        <NativeTabs.Trigger.Label>Search</NativeTabs.Trigger.Label>
      </NativeTabs.Trigger>
    </NativeTabs>
  );
}
