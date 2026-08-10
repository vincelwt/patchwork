import { useWindowDimensions } from "react-native";

/// Where the app is being read: a phone, a phone turned sideways, an iPad, or
/// an iPad sharing the screen with something else. Driven by the window rather
/// than the device so Split View and Stage Manager get the same treatment.
///
/// One scale for every surface. A screen that invents its own inset is the
/// reason a big screen stops looking deliberate, so everything that touches an
/// edge takes `gutter` from here.
export interface Layout {
  width: number;
  /// Room enough to keep a list on screen next to what it opens.
  split: boolean;
  /// Wide enough that full-bleed text would run past a comfortable measure.
  wide: boolean;
  /// The reading measure centred content stays inside.
  measure: number;
  /// The distance from content to the edge it sits nearest.
  gutter: number;
}

const SPLIT_AT = 820;
/// A phone on its side is wide enough for two columns and far too short for
/// them: a list, a conversation and a keyboard do not share 440pt of height.
const SPLIT_NEEDS_HEIGHT = 600;
const WIDE_AT = 680;

export function useLayout(): Layout {
  const { width, height } = useWindowDimensions();
  const wide = width >= WIDE_AT;
  return {
    width,
    split: width >= SPLIT_AT && height >= SPLIT_NEEDS_HEIGHT,
    wide,
    measure: Math.min(width, 760),
    gutter: wide ? 28 : 16,
  };
}
