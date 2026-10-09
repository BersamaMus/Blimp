#ifndef RUNNER_WINDOW_PLACEMENT_H_
#define RUNNER_WINDOW_PLACEMENT_H_

#include <windows.h>

// Remembers the window's size, position and whether it was maximized
// between launches, in the registry under HKCU\Software\Blimp\Blimp.

// Saves |window|'s placement, as it closes.
void SaveWindowPlacement(HWND window);

// Moves and sizes the still-hidden |window| as it was last closed. Returns
// whether it was maximized then, so it can be shown that way; false, and
// the window left as created, on a first launch.
bool RestoreWindowPlacement(HWND window);

#endif  // RUNNER_WINDOW_PLACEMENT_H_
