import { useLocalSearchParams } from "expo-router";

import { TaskDetail } from "@/components/TaskDetail";

export default function TaskScreen() {
  const { taskId } = useLocalSearchParams<{ taskId: string }>();
  return <TaskDetail taskId={taskId} />;
}
