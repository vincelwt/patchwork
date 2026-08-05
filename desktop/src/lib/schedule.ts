// Saying when something should happen, without making anyone write cron.
//
// "Every day" is the thing people actually ask for, and it is *not* "every 1440
// minutes" — that drifts to whatever time you happened to press the button. So
// the presets produce real cron expressions, and the custom escape hatch is
// there for the person who wanted cron all along.

export interface SchedulePreset {
  id: string;
  label: string;
  /// Builds the expression from the chosen time and weekday.
  cron: (time: string, weekday: number) => string;
  needsTime: boolean;
  needsWeekday: boolean;
}

const hhmm = (time: string) => {
  const [h, m] = time.split(":");
  return { hour: Number(h) || 0, minute: Number(m) || 0 };
};

export const PRESETS: SchedulePreset[] = [
  {
    id: "hourly",
    label: "Every hour",
    cron: () => "0 * * * *",
    needsTime: false,
    needsWeekday: false,
  },
  {
    id: "daily",
    label: "Every day",
    cron: (time) => {
      const { hour, minute } = hhmm(time);
      return `${minute} ${hour} * * *`;
    },
    needsTime: true,
    needsWeekday: false,
  },
  {
    id: "weekdays",
    label: "Every weekday",
    cron: (time) => {
      const { hour, minute } = hhmm(time);
      return `${minute} ${hour} * * 1-5`;
    },
    needsTime: true,
    needsWeekday: false,
  },
  {
    id: "weekly",
    label: "Every week",
    cron: (time, weekday) => {
      const { hour, minute } = hhmm(time);
      return `${minute} ${hour} * * ${weekday}`;
    },
    needsTime: true,
    needsWeekday: true,
  },
];

export const WEEKDAYS = [
  "Sunday",
  "Monday",
  "Tuesday",
  "Wednesday",
  "Thursday",
  "Friday",
  "Saturday",
];

/// Plain English for a cron expression, falling back to the expression itself
/// rather than to a lie.
export function describeCron(expression: string): string {
  const parts = expression.trim().split(/\s+/);
  if (parts.length !== 5) return expression;
  const [minute, hour, day, month, weekday] = parts;

  const at = () => {
    const h = Number(hour);
    const m = Number(minute);
    if (Number.isNaN(h) || Number.isNaN(m)) return null;
    return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`;
  };

  if (day === "*" && month === "*") {
    const time = at();
    if (hour === "*" && minute === "0") return "every hour";
    if (!time) return expression;
    if (weekday === "*") return `every day at ${time}`;
    if (weekday === "1-5") return `every weekday at ${time}`;
    const single = Number(weekday);
    if (!Number.isNaN(single) && WEEKDAYS[single]) {
      return `every ${WEEKDAYS[single]} at ${time}`;
    }
  }
  return expression;
}

/// Which preset produced an expression, so editing reopens where you left off.
export function presetFor(expression: string): {
  preset: string;
  time: string;
  weekday: number;
} {
  const parts = expression.trim().split(/\s+/);
  if (parts.length === 5) {
    const [minute, hour, day, month, weekday] = parts;
    const time = `${String(Number(hour) || 0).padStart(2, "0")}:${String(
      Number(minute) || 0,
    ).padStart(2, "0")}`;
    if (day === "*" && month === "*") {
      if (hour === "*") return { preset: "hourly", time: "09:00", weekday: 1 };
      if (weekday === "*") return { preset: "daily", time, weekday: 1 };
      if (weekday === "1-5") return { preset: "weekdays", time, weekday: 1 };
      const single = Number(weekday);
      if (!Number.isNaN(single)) return { preset: "weekly", time, weekday: single };
    }
  }
  return { preset: "custom", time: "09:00", weekday: 1 };
}
