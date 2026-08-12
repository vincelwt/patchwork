/// How much room a bottom-anchored bar still needs to clear the software
/// keyboard, given the `applied` points of safe area it already reserves.
///
/// The two platforms measure the keyboard from different places. Android
/// reports its height above the system bars (`imeInsets.bottom -
/// barInsets.bottom`), so it stacks on top of a bar's own inset. iOS reports it
/// from the bottom of the window, so it already covers that inset and only the
/// difference is left to add.
export function keyboardInset(keyboard: number, applied: number, ios: boolean): number {
  if (keyboard <= 0) return 0;
  return ios ? Math.max(keyboard - applied, 0) : keyboard;
}
