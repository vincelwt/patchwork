import { useWindowDimensions } from "react-native";

/// Where the app is being read: a phone, a phone turned sideways, an iPad, or
/// an iPad sharing the screen with something else. Driven by the window rather
/// than the device so Split View and Stage Manager get the same treatment.
export interface Layout {
  width: number;
  /// Room enough to keep a list on screen next to what it opens.
  split: boolean;
  /// Wide enough that full-bleed text would run past a comfortable measure.
  wide: boolean;
  /// The reading measure centred content should stay inside.
  measure: number;
}

const SPLIT_AT = 820;
const WIDE_AT = 680;
const MEASURE = 720;

export function useLayout(): Layout {
  const { width } = useWindowDimensions();
  return {
    width,
    split: width >= SPLIT_AT,
    wide: width >= WIDE_AT,
    measure: Math.min(width, MEASURE),
  };
}
