/* Counts the windows a player can get back to: visible top-level windows, minimized ones
 * included, of every program in the bottle. Exits with the count (at most 255) and prints them.
 *
 * Corkscrew uses it to tell a closed Steam from a minimized one. Steam's close button only hides
 * its window and keeps Steam running in the tray; macOS reports a hidden Wine window and a
 * minimized one alike (off screen), but Windows doesn't. */
#include <windows.h>
#include <stdio.h>

static int count;

static BOOL CALLBACK visit(HWND hwnd, LPARAM unused)
{
    WCHAR title[128] = L"";
    char text[512];
    RECT rect;
    DWORD pid = 0;

    if (!IsWindowVisible(hwnd)) return TRUE;
    if (GetWindowLongW(hwnd, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) return TRUE;
    if (!GetWindowRect(hwnd, &rect) || rect.right <= rect.left || rect.bottom <= rect.top) return TRUE;
    GetWindowTextW(hwnd, title, ARRAYSIZE(title));
    GetWindowThreadProcessId(hwnd, &pid);
    /* UTF-8: wprintf stops at the first character the C locale can't show. */
    WideCharToMultiByte(CP_UTF8, 0, title, -1, text, sizeof(text), NULL, NULL);
    printf("%04lx %s%s\n", pid, text, IsIconic(hwnd) ? " (minimized)" : "");
    count++;
    return TRUE;
}

int wmain(void)
{
    EnumWindows(visit, 0);
    return count > 255 ? 255 : count;
}
