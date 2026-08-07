// One outline set, 1.5px strokes on a 24 grid, always `currentColor`.
// Icons carry meaning here, never decoration — a row without something to say
// does not get one.

interface IconProps {
  size?: number;
  className?: string;
}

function Svg({
  size = 18,
  className,
  children,
}: IconProps & { children: React.ReactNode }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.6}
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      aria-hidden="true"
    >
      {children}
    </svg>
  );
}

export const InboxIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M4 13h4l1.5 2.5h5L16 13h4" />
    <path d="M5.4 5.6h13.2l1.4 7.4v4a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2v-4z" />
  </Svg>
);

export const TasksIcon = (props: IconProps) => (
  <Svg {...props}>
    <rect x="3.5" y="4.5" width="6" height="15" rx="1.6" />
    <rect x="14.5" y="4.5" width="6" height="9" rx="1.6" />
  </Svg>
);

export const HashIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M9.5 4 8 20M16 4l-1.5 16M4.5 9h15M3.5 15h15" />
  </Svg>
);

export const SearchIcon = (props: IconProps) => (
  <Svg {...props}>
    <circle cx="11" cy="11" r="6.5" />
    <path d="m20 20-3.6-3.6" />
  </Svg>
);

export const ChevronIcon = ({ open = true, ...props }: IconProps & { open?: boolean }) => (
  <Svg {...props}>
    <path d={open ? "m6 9.5 6 6 6-6" : "m9.5 6 6 6-6 6"} />
  </Svg>
);

export const PlusIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M12 5v14M5 12h14" />
  </Svg>
);

export const AttachIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M20 11.5 12.3 19a4.6 4.6 0 0 1-6.5-6.5l7.9-7.9a3 3 0 1 1 4.3 4.3l-7.8 7.8a1.5 1.5 0 0 1-2.1-2.1l7.1-7.1" />
  </Svg>
);

export const MicIcon = (props: IconProps) => (
  <Svg {...props}>
    <rect x="9" y="3" width="6" height="11" rx="3" />
    <path d="M5.5 11.5a6.5 6.5 0 0 0 13 0M12 18v3" />
  </Svg>
);

export const SendIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M12 19V6M6 11.5 12 5.5l6 6" />
  </Svg>
);

export const ThreadIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M4 8.5A3.5 3.5 0 0 1 7.5 5h9A3.5 3.5 0 0 1 20 8.5v3a3.5 3.5 0 0 1-3.5 3.5H10l-4 3.5V15H7.5A3.5 3.5 0 0 1 4 11.5z" />
  </Svg>
);

export const ReactIcon = (props: IconProps) => (
  <Svg {...props}>
    <circle cx="12" cy="12" r="8.2" />
    <path d="M8.8 14.2a4 4 0 0 0 6.4 0" />
    <path d="M9.3 9.6h.01M14.7 9.6h.01" />
  </Svg>
);

export const BranchIcon = (props: IconProps) => (
  <Svg {...props}>
    <circle cx="7" cy="6" r="2.2" />
    <circle cx="7" cy="18" r="2.2" />
    <circle cx="17" cy="9" r="2.2" />
    <path d="M7 8.2v7.6M17 11.2c0 3-2.6 4.3-5.6 4.6" />
  </Svg>
);

export const ExternalIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M14 5h5v5M19 5l-7.5 7.5" />
    <path d="M18 14.5V18a1.5 1.5 0 0 1-1.5 1.5H6A1.5 1.5 0 0 1 4.5 18V7.5A1.5 1.5 0 0 1 6 6h3.5" />
  </Svg>
);

export const FolderIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M3.5 7.2A1.7 1.7 0 0 1 5.2 5.5h3.4l1.8 2h8.4a1.7 1.7 0 0 1 1.7 1.7v7.6a1.7 1.7 0 0 1-1.7 1.7H5.2a1.7 1.7 0 0 1-1.7-1.7z" />
  </Svg>
);

export const RunIcon = (props: IconProps) => (
  <Svg {...props}>
    <circle cx="12" cy="12" r="8.2" />
    <path d="M10.2 9.2 15 12l-4.8 2.8z" />
  </Svg>
);

export const QuestionIcon = (props: IconProps) => (
  <Svg {...props}>
    <circle cx="12" cy="12" r="8.2" />
    <path d="M9.8 9.6a2.2 2.2 0 1 1 2.9 2.1c-.5.2-.7.6-.7 1.1v.5" />
    <path d="M12 16.6h.01" />
  </Svg>
);

export const AutomationIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M13.5 3 5.5 13.2h5L10 21l8.2-10.3h-5.2z" />
  </Svg>
);

export const AgentIcon = (props: IconProps) => (
  <Svg {...props}>
    <rect x="4.5" y="7.5" width="15" height="11" rx="3" />
    <path d="M12 4v3.5M9.4 12.4h.01M14.6 12.4h.01M10 15.6h4" />
  </Svg>
);

export const MembersIcon = (props: IconProps) => (
  <Svg {...props}>
    <circle cx="9.5" cy="9" r="3.2" />
    <path d="M3.8 19a5.8 5.8 0 0 1 11.4 0" />
    <path d="M16 6.4a3.2 3.2 0 0 1 0 5.9M17.6 14.6a5.4 5.4 0 0 1 2.6 4.4" />
  </Svg>
);

export const SettingsIcon = (props: IconProps) => (
  <Svg {...props}>
    <circle cx="12" cy="12" r="2.8" />
    <path d="M12 3.5v2.2M12 18.3v2.2M20.5 12h-2.2M5.7 12H3.5M18 6l-1.6 1.6M7.6 16.4 6 18M18 18l-1.6-1.6M7.6 7.6 6 6" />
  </Svg>
);

export const PreviewIcon = (props: IconProps) => (
  <Svg {...props}>
    <rect x="3.5" y="5" width="17" height="12.5" rx="2" />
    <path d="M3.5 9h17M6.6 7h.01M9 7h.01" />
  </Svg>
);

export const CheckIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="m5.5 12.5 4 4 9-9" />
  </Svg>
);

export const CloseIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="m6 6 12 12M18 6 6 18" />
  </Svg>
);

export const BackIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M19 12H5M11 6l-6 6 6 6" />
  </Svg>
);

export const TerminalIcon = (props: IconProps) => (
  <Svg {...props}>
    <rect x="3.5" y="5" width="17" height="14" rx="2.4" />
    <path d="m7.5 10 2.5 2-2.5 2M12.5 14.5h4" />
  </Svg>
);

export const WarningIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M12 4.6 21 19.4H3z" />
    <path d="M12 10.4v3.4M12 16.6h.01" />
  </Svg>
);

export const FileIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M13.5 3.5H7A1.5 1.5 0 0 0 5.5 5v14A1.5 1.5 0 0 0 7 20.5h10a1.5 1.5 0 0 0 1.5-1.5V8.5z" />
    <path d="M13.5 3.5v5h5" />
  </Svg>
);

export const ShieldIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M12 3.6 19 6v5.4c0 4-2.9 7.4-7 8.9-4.1-1.5-7-4.9-7-8.9V6z" />
    <path d="m9.2 12 2 2 3.6-3.8" />
  </Svg>
);

/// An agent's own progress note.
export const PulseIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M3.5 12h3.2l2-5 3.4 10 2.2-6 1.6 3h4.6" />
  </Svg>
);

/// A workspace event: something happened, nobody said it.
export const EventIcon = (props: IconProps) => (
  <Svg {...props}>
    <circle cx="12" cy="12" r="3.4" />
  </Svg>
);

/// A quiet indeterminate ring — the "something is happening" glyph.
export const CopyIcon = (props: IconProps) => (
  <Svg {...props}>
    <rect x="9" y="9" width="11" height="11" rx="2.2" />
    <path d="M15 6.2A2.2 2.2 0 0 0 12.8 4H6.2A2.2 2.2 0 0 0 4 6.2v6.6A2.2 2.2 0 0 0 6.2 15" />
  </Svg>
);

export const PlayIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M8 5.6 18.4 12 8 18.4z" fill="currentColor" stroke="none" />
  </Svg>
);

export const StopIcon = (props: IconProps) => (
  <Svg {...props}>
    <rect x="7" y="7" width="10" height="10" rx="2" fill="currentColor" stroke="none" />
  </Svg>
);

export const PencilIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M4.5 19.5h3.2L18.9 8.3a2.3 2.3 0 0 0-3.2-3.2L4.5 16.3z" />
    <path d="M14.6 6.2 17.8 9.4" />
  </Svg>
);

export const TrashIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M4.8 6.6h14.4" />
    <path d="M9.4 6.6V5.2A1.4 1.4 0 0 1 10.8 3.8h2.4a1.4 1.4 0 0 1 1.4 1.4v1.4" />
    <path d="M6.6 6.6 7.5 19a1.4 1.4 0 0 0 1.4 1.3h6.2a1.4 1.4 0 0 0 1.4-1.3l.9-12.4" />
  </Svg>
);

export const MoreIcon = (props: IconProps) => (
  <Svg {...props}>
    <circle cx="6" cy="12" r="1.35" fill="currentColor" stroke="none" />
    <circle cx="12" cy="12" r="1.35" fill="currentColor" stroke="none" />
    <circle cx="18" cy="12" r="1.35" fill="currentColor" stroke="none" />
  </Svg>
);

export const ArrowIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M5 12h14" />
    <path d="m13 6 6 6-6 6" />
  </Svg>
);

export const KeyboardIcon = (props: IconProps) => (
  <Svg {...props}>
    <rect x="2.8" y="6.4" width="18.4" height="11.2" rx="2.2" />
    <path d="M7 10h.01M10.5 10h.01M14 10h.01M17.5 10h.01M8.5 14h7" />
  </Svg>
);

export const ClockIcon = (props: IconProps) => (
  <Svg {...props}>
    <circle cx="12" cy="12" r="8.4" />
    <path d="M12 7.6V12l2.8 1.8" />
  </Svg>
);

export const Spinner = ({ size = 14 }: IconProps) => (
  <svg
    width={size}
    height={size}
    viewBox="0 0 24 24"
    fill="none"
    className="spinner"
    aria-hidden="true"
  >
    <circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="2.4" opacity="0.22" />
    <path
      d="M21 12a9 9 0 0 0-9-9"
      stroke="currentColor"
      strokeWidth="2.4"
      strokeLinecap="round"
    />
  </svg>
);
