#ifndef RUNNER_WINDOW_PLACEMENT_H_
#define RUNNER_WINDOW_PLACEMENT_H_

#include <windows.h>

// Remembers the window's size, position and whether it was maximized
// between launches, in the registry under HKCU\Software\Blimp\Blimp.

// Saves |window|'s placement, as it closes.
void SaveWindowPlacement(HWND window);

// Moves and sizes the still-hidden |window| as it was last closed. Returns
// whether to show it maximized: as it was then, or, on a first launch (the
// window left as created), true, so Blimp first opens filling the screen.
bool RestoreWindowPlacement(HWND window);

#endif  // RUNNER_WINDOW_PLACEMENT_H_
