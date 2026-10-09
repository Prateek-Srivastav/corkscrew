/* Prints the display information Windows programs see: monitors, work areas, DPI, metrics. */
#include <windows.h>
#include <stdio.h>

static BOOL CALLBACK show(HMONITOR monitor, HDC dc, LPRECT rect, LPARAM data)
{
    MONITORINFOEXA info = { .cbSize = sizeof(info) };
    GetMonitorInfoA(monitor, (MONITORINFO *)&info);
    printf("monitor %s%s: rect=(%ld,%ld)-(%ld,%ld) work=(%ld,%ld)-(%ld,%ld)\n", info.szDevice,
           info.dwFlags & MONITORINFOF_PRIMARY ? " primary" : "",
           info.rcMonitor.left, info.rcMonitor.top, info.rcMonitor.right, info.rcMonitor.bottom,
           info.rcWork.left, info.rcWork.top, info.rcWork.right, info.rcWork.bottom);
    return TRUE;
}

int main(void)
{
    SetProcessDPIAware();
    EnumDisplayMonitors(NULL, NULL, show, 0);
    printf("screen=%dx%d virtual=(%d,%d) %dx%d dpi=%u\n", GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN),
           GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN),
           GetSystemMetrics(SM_CXVIRTUALSCREEN), GetSystemMetrics(SM_CYVIRTUALSCREEN), GetDpiForSystem());
    return 0;
}
