import { NativeTabs } from "expo-router/unstable-native-tabs";

import { unreadInboxCount } from "@client/inbox";
import { useWorkspace } from "@/lib/store";
import { useTheme } from "@/lib/theme";

export default function TabLayout() {
  const theme = useTheme();
  const bootstrap = useWorkspace().bootstrap;
  const unread = unreadInboxCount(bootstrap?.inbox ?? []);

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
      <NativeTabs.Trigger name="home">
        <NativeTabs.Trigger.Icon sf={{ default: "tray", selected: "tray.fill" }} md="inbox" />
        <NativeTabs.Trigger.Label>Home</NativeTabs.Trigger.Label>
        {unread ? <NativeTabs.Trigger.Badge>{String(Math.min(unread, 99))}</NativeTabs.Trigger.Badge> : null}
      </NativeTabs.Trigger>
      <NativeTabs.Trigger name="channels">
        <NativeTabs.Trigger.Icon
          sf={{ default: "bubble.left.and.bubble.right", selected: "bubble.left.and.bubble.right.fill" }}
          md="forum"
        />
        <NativeTabs.Trigger.Label>Chats</NativeTabs.Trigger.Label>
      </NativeTabs.Trigger>
      <NativeTabs.Trigger name="search" role="search">
        <NativeTabs.Trigger.Icon sf="magnifyingglass" md="search" />
        <NativeTabs.Trigger.Label>Search</NativeTabs.Trigger.Label>
      </NativeTabs.Trigger>
    </NativeTabs>
  );
}
