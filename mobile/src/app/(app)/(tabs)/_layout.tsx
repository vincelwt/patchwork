import { NativeTabs } from "expo-router/unstable-native-tabs";

import { useWorkspace } from "@/lib/store";
import { useTheme } from "@/lib/theme";

export default function TabLayout() {
  const theme = useTheme();
  const unread = useWorkspace().bootstrap?.inbox.filter((item) => !item.read_at).length ?? 0;

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
        <NativeTabs.Trigger.Icon sf={{ default: "ellipsis.circle", selected: "ellipsis.circle.fill" }} md="more_horiz" />
        <NativeTabs.Trigger.Label>More</NativeTabs.Trigger.Label>
      </NativeTabs.Trigger>
      <NativeTabs.Trigger name="search" role="search">
        <NativeTabs.Trigger.Icon sf="magnifyingglass" md="search" />
        <NativeTabs.Trigger.Label>Search</NativeTabs.Trigger.Label>
      </NativeTabs.Trigger>
    </NativeTabs>
  );
}
