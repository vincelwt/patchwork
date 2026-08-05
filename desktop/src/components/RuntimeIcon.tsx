// Brand marks for the agent runtimes. The set in `icons.tsx` is stroked
// outlines because those icons say what a thing does; these say *whose* it is,
// and a logo is a silhouette you recognise before you read the label — traced
// as a 1.6px outline it stops being either. So: same 24 grid, same
// `currentColor`, filled. Every mark is hand-drawn down to what still reads at
// 15px, which is roughly one shape and a gap.

const CLAUDE_STROKES = [0, 60, 120];

export function RuntimeIcon({
  runtime,
  size = 15,
}: {
  runtime: string;
  size?: number;
}) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="currentColor"
      stroke="none"
      aria-hidden="true"
    >
      {mark(runtime)}
    </svg>
  );
}

/// An id we have never heard of still has to draw something, and "some command
/// on a machine" is the only honest thing left to say about it.
function mark(runtime: string): React.ReactNode {
  switch (runtime) {
    case "codex":
      // The knot, which at this size is a hexagonal ring and nothing else.
      return (
        <path
          fillRule="evenodd"
          d="M12 2l8.7 5v10L12 22l-8.7-5V7zm0 3.4L6.3 8.7v6.6l5.7 3.3 5.7-3.3V8.7z"
        />
      );

    case "claude":
      // Three strokes crossing at the centre, which is all the burst ever is.
      return CLAUDE_STROKES.map((angle) => (
        <rect
          key={angle}
          x="10.8"
          y="3.2"
          width="2.4"
          height="17.6"
          rx="1.2"
          transform={`rotate(${angle} 12 12)`}
        />
      ));

    case "gemini":
      // The four-pointed spark: straight points, concave waists.
      return (
        <path d="M12 2c.7 5.4 4.6 9.3 10 10-5.4.7-9.3 4.6-10 10-.7-5.4-4.6-9.3-10-10 5.4-.7 9.3-4.6 10-10z" />
      );

    case "grok":
      // One long slash with the counter-diagonal broken either side of it.
      return (
        <>
          <path d="M3.4 20.6h4.8L20.6 3.4h-4.8z" />
          <path d="M3.4 3.4h4.8l3.4 4.7-2.4 3.3z" />
          <path d="M20.6 20.6h-4.8l-3.4-4.7 2.4-3.3z" />
        </>
      );

    case "opencode":
      // A solid block with the prompt cut out of it, rather than drawn on it.
      return (
        <path
          fillRule="evenodd"
          d="M4.6 3.6h14.8A2.6 2.6 0 0 1 22 6.2v11.6a2.6 2.6 0 0 1-2.6 2.6H4.6A2.6 2.6 0 0 1 2 17.8V6.2a2.6 2.6 0 0 1 2.6-2.6ZM7.5 8.3 6.2 9.6l2.6 2.6-2.6 2.6 1.3 1.3 3.9-3.9ZM12.6 14.5h4.6v1.9h-4.6Z"
        />
      );

    case "pi":
      return <path d="M3.4 5.6h17.2v2.7h-2.2v10.1h-2.7V8.3H8.3v10.1H5.6V8.3H3.4z" />;

    case "patchwork":
      // The app's own icon: four patches, one grid, nothing else.
      return (
        <>
          <rect x="2.6" y="2.6" width="8.6" height="8.6" rx="2.9" />
          <rect x="12.8" y="2.6" width="8.6" height="8.6" rx="2.9" />
          <rect x="2.6" y="12.8" width="8.6" height="8.6" rx="2.9" />
          <rect x="12.8" y="12.8" width="8.6" height="8.6" rx="2.9" />
        </>
      );

    default:
      return (
        <>
          <path d="M5.9 4.7 4 6.6l5.4 5.4L4 17.4l1.9 1.9 7.3-7.3z" />
          <rect x="12.6" y="17" width="7.4" height="2.2" rx="1.1" />
        </>
      );
  }
}
