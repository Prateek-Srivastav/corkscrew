/* Benchmark: D3D11 draw-call throughput, the CPU cost a translation layer adds per draw.
 * Each frame updates a constant buffer and draws a tiny triangle DRAWS times, so the GPU has
 * almost nothing to do and the frame time is the CPU time in the game, Wine and the backend.
 * Usage: dx11_draws.exe [draws per frame (default 2000)] [seconds (default 5)] [fullscreen]
 * "fullscreen" draws in a borderless window that covers the screen, as most games do.
 * Prints api=, adapter=, then fps=, ms_per_frame=, cpu_ms_per_frame=, and exits 0 on success. */
#define COBJMACROS
#include <initguid.h>
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <dxgi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int width = 640, height = 360;
#define CHECK(call) do { HRESULT hr_ = (call); \
    if (FAILED(hr_)) { printf("FAIL %s hr=0x%08lx\n", #call, (unsigned long)hr_); return 1; } } while (0)

static const char shader[] =
    "cbuffer c : register(b0) { float4 offset; };\n"
    "float4 vs(uint id : SV_VertexID) : SV_Position {\n"
    "    float2 p = float2(id == 1, id == 2) * 0.01;\n"
    "    return float4(p + offset.xy, 0, 1);\n"
    "}\n"
    "float4 ps() : SV_Target { return float4(1, 0.5, 0, 1); }\n";

typedef HRESULT (WINAPI *compile_fn)(const void *, SIZE_T, const char *, const D3D_SHADER_MACRO *, ID3DInclude *,
                                     const char *, const char *, UINT, UINT, ID3DBlob **, ID3DBlob **);

static LRESULT CALLBACK window_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam)
{
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

static double cpu_seconds(void)
{
    FILETIME created, exited, kernel, user;
    GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user);
    ULARGE_INTEGER k = { .LowPart = kernel.dwLowDateTime, .HighPart = kernel.dwHighDateTime };
    ULARGE_INTEGER u = { .LowPart = user.dwLowDateTime, .HighPart = user.dwHighDateTime };
    return (k.QuadPart + u.QuadPart) / 1e7;
}

int main(int argc, char **argv)
{
    int draws = argc > 1 ? atoi(argv[1]) : 2000;
    double seconds = argc > 2 ? atof(argv[2]) : 5;
    BOOL fullscreen = argc > 3 && !strcmp(argv[3], "fullscreen");
    DWORD style = WS_OVERLAPPEDWINDOW | WS_VISIBLE;
    int x = 100, y = 100;
    if (fullscreen) {
        width = GetSystemMetrics(SM_CXSCREEN);
        height = GetSystemMetrics(SM_CYSCREEN);
        style = WS_POPUP | WS_VISIBLE;
        x = y = 0;
    }
    WNDCLASSW wc = {0};
    wc.lpfnWndProc = window_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"cs_dx11_draws";
    RegisterClassW(&wc);
    HWND hwnd = CreateWindowW(L"cs_dx11_draws", L"Corkscrew D3D11 draw benchmark", style,
                              x, y, width, height, NULL, NULL, wc.hInstance, NULL);

    DXGI_SWAP_CHAIN_DESC sd = {0};
    sd.BufferCount = 2;
    sd.BufferDesc.Width = width;
    sd.BufferDesc.Height = height;
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
    printf("api=d3d11 adapter=\"%s\" draws=%d\n", name, draws);

    HMODULE compiler = LoadLibraryA("d3dcompiler_47.dll");
    compile_fn compile = compiler ? (compile_fn)GetProcAddress(compiler, "D3DCompile") : NULL;
    if (!compile) { printf("FAIL d3dcompiler_47.dll\n"); return 1; }
    ID3DBlob *vs_code, *ps_code, *errors = NULL;
    CHECK(compile(shader, sizeof(shader) - 1, "draws", NULL, NULL, "vs", "vs_4_0", 0, 0, &vs_code, &errors));
    CHECK(compile(shader, sizeof(shader) - 1, "draws", NULL, NULL, "ps", "ps_4_0", 0, 0, &ps_code, &errors));
    ID3D11VertexShader *vs;
    ID3D11PixelShader *ps;
    CHECK(ID3D11Device_CreateVertexShader(device, ID3D10Blob_GetBufferPointer(vs_code), ID3D10Blob_GetBufferSize(vs_code), NULL, &vs));
    CHECK(ID3D11Device_CreatePixelShader(device, ID3D10Blob_GetBufferPointer(ps_code), ID3D10Blob_GetBufferSize(ps_code), NULL, &ps));

    D3D11_BUFFER_DESC bd = { .ByteWidth = 16, .Usage = D3D11_USAGE_DYNAMIC, .BindFlags = D3D11_BIND_CONSTANT_BUFFER,
                             .CPUAccessFlags = D3D11_CPU_ACCESS_WRITE };
    ID3D11Buffer *constants;
    CHECK(ID3D11Device_CreateBuffer(device, &bd, NULL, &constants));

    ID3D11Texture2D *backbuffer;
    ID3D11RenderTargetView *rtv;
    CHECK(IDXGISwapChain_GetBuffer(swapchain, 0, &IID_ID3D11Texture2D, (void **)&backbuffer));
    CHECK(ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)backbuffer, NULL, &rtv));
    D3D11_VIEWPORT viewport = { 0, 0, width, height, 0, 1 };
    const float clear[4] = { 0.1f, 0.2f, 0.4f, 1.0f };

    LARGE_INTEGER frequency, start, now;
    QueryPerformanceFrequency(&frequency);
    double cpu_start = 0;
    int frames = 0, warmup = 60;
    for (;;) {
        MSG msg;
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
        if (frames == warmup) { QueryPerformanceCounter(&start); cpu_start = cpu_seconds(); }
        ID3D11DeviceContext_OMSetRenderTargets(context, 1, &rtv, NULL);
        ID3D11DeviceContext_RSSetViewports(context, 1, &viewport);
        ID3D11DeviceContext_ClearRenderTargetView(context, rtv, clear);
        ID3D11DeviceContext_IASetPrimitiveTopology(context, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        ID3D11DeviceContext_VSSetShader(context, vs, NULL, 0);
        ID3D11DeviceContext_PSSetShader(context, ps, NULL, 0);
        ID3D11DeviceContext_VSSetConstantBuffers(context, 0, 1, &constants);
        for (int i = 0; i < draws; i++) {
            D3D11_MAPPED_SUBRESOURCE mapped;
            CHECK(ID3D11DeviceContext_Map(context, (ID3D11Resource *)constants, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped));
            float *offset = mapped.pData;
            offset[0] = (i % 64) / 32.0f - 1;
            offset[1] = (i / 64 % 64) / 32.0f - 1;
            offset[2] = offset[3] = 0;
            ID3D11DeviceContext_Unmap(context, (ID3D11Resource *)constants, 0);
            ID3D11DeviceContext_Draw(context, 3, 0);
        }
        CHECK(IDXGISwapChain_Present(swapchain, 0, 0));
        frames++;
        QueryPerformanceCounter(&now);
        if (frames > warmup && (double)(now.QuadPart - start.QuadPart) / frequency.QuadPart >= seconds) break;
    }
    double elapsed = (double)(now.QuadPart - start.QuadPart) / frequency.QuadPart;
    int measured = frames - warmup;
    printf("frames=%d fps=%.1f ms_per_frame=%.3f cpu_ms_per_frame=%.3f\n", measured, measured / elapsed,
           elapsed * 1000 / measured, (cpu_seconds() - cpu_start) * 1000 / measured);
    return 0;
}
