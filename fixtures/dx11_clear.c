/* Smoke test: creates a D3D11 device and swap chain, clears and presents N frames (default 120),
 * prints the adapter and frame rate, and exits 0 on success. */
#define COBJMACROS
#include <initguid.h>
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>
#include <stdlib.h>

#define WIDTH 640
#define HEIGHT 360
#define CHECK(call) do { HRESULT hr_ = (call); \
    if (FAILED(hr_)) { printf("FAIL %s hr=0x%08lx\n", #call, (unsigned long)hr_); return 1; } } while (0)

static LRESULT CALLBACK window_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam)
{
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

int main(int argc, char **argv)
{
    int frames = argc > 1 ? atoi(argv[1]) : 120;
    WNDCLASSW wc = {0};
    wc.lpfnWndProc = window_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"cs_dx11";
    RegisterClassW(&wc);
    HWND hwnd = CreateWindowW(L"cs_dx11", L"Corkscrew D3D11 test", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                              100, 100, WIDTH, HEIGHT, NULL, NULL, wc.hInstance, NULL);

    DXGI_SWAP_CHAIN_DESC sd = {0};
    sd.BufferCount = 2;
    sd.BufferDesc.Width = WIDTH;
    sd.BufferDesc.Height = HEIGHT;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hwnd;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;

    ID3D11Device *device;
    ID3D11DeviceContext *context;
    IDXGISwapChain *swapchain;
    D3D_FEATURE_LEVEL level;
    CHECK(D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION,
                                        &sd, &swapchain, &device, &level, &context));

    IDXGIDevice *dxgi_device;
    IDXGIAdapter *adapter;
    DXGI_ADAPTER_DESC desc;
    char name[128];
    CHECK(ID3D11Device_QueryInterface(device, &IID_IDXGIDevice, (void **)&dxgi_device));
    CHECK(IDXGIDevice_GetAdapter(dxgi_device, &adapter));
    CHECK(IDXGIAdapter_GetDesc(adapter, &desc));
    WideCharToMultiByte(CP_UTF8, 0, desc.Description, -1, name, sizeof(name), NULL, NULL);
    printf("api=d3d11 adapter=\"%s\" feature_level=0x%x\n", name, level);

    ID3D11Texture2D *backbuffer;
    ID3D11RenderTargetView *rtv;
    CHECK(IDXGISwapChain_GetBuffer(swapchain, 0, &IID_ID3D11Texture2D, (void **)&backbuffer));
    CHECK(ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)backbuffer, NULL, &rtv));

    LARGE_INTEGER freq, start, end;
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&start);
    for (int i = 0; i < frames; i++)
    {
        MSG msg;
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) DispatchMessageW(&msg);
        float color[4] = { (i % 60) / 60.0f, 0.2f, 0.6f, 1.0f };
        ID3D11DeviceContext_OMSetRenderTargets(context, 1, &rtv, NULL);
        ID3D11DeviceContext_ClearRenderTargetView(context, rtv, color);
        CHECK(IDXGISwapChain_Present(swapchain, 0, 0));
    }
    QueryPerformanceCounter(&end);
    printf("frames=%d fps=%.0f\n", frames, frames * (double)freq.QuadPart / (end.QuadPart - start.QuadPart));
    return 0;
}
