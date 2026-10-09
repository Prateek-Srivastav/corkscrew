/* Smoke test: creates a D3D12 device, queue and flip-model swap chain, clears and presents N frames
 * (default 120) with a fence per frame, prints the adapter and frame rate, and exits 0 on success. */
#define COBJMACROS
#define WIDL_C_INLINE_WRAPPERS
#include <initguid.h>
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <stdio.h>
#include <stdlib.h>

#define WIDTH 640
#define HEIGHT 360
#define BUFFERS 2
#define CHECK(call) do { HRESULT hr_ = (call); \
    if (FAILED(hr_)) { printf("FAIL %s hr=0x%08lx\n", #call, (unsigned long)hr_); return 1; } } while (0)

static LRESULT CALLBACK window_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam)
{
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

static void transition(ID3D12GraphicsCommandList *list, ID3D12Resource *resource,
                       D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after)
{
    D3D12_RESOURCE_BARRIER barrier = {0};
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition.pResource = resource;
    barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    barrier.Transition.StateBefore = before;
    barrier.Transition.StateAfter = after;
    ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &barrier);
}

int main(int argc, char **argv)
{
    int frames = argc > 1 ? atoi(argv[1]) : 120;
    WNDCLASSW wc = {0};
    wc.lpfnWndProc = window_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"cs_dx12";
    RegisterClassW(&wc);
    HWND hwnd = CreateWindowW(L"cs_dx12", L"Corkscrew D3D12 test", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                              100, 100, WIDTH, HEIGHT, NULL, NULL, wc.hInstance, NULL);

    IDXGIFactory4 *factory;
    IDXGIAdapter1 *adapter;
    DXGI_ADAPTER_DESC1 desc;
    char name[128];
    CHECK(CreateDXGIFactory1(&IID_IDXGIFactory4, (void **)&factory));
    CHECK(IDXGIFactory4_EnumAdapters1(factory, 0, &adapter));
    CHECK(IDXGIAdapter1_GetDesc1(adapter, &desc));
    WideCharToMultiByte(CP_UTF8, 0, desc.Description, -1, name, sizeof(name), NULL, NULL);

    ID3D12Device *device;
    CHECK(D3D12CreateDevice((IUnknown *)adapter, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&device));
    printf("api=d3d12 adapter=\"%s\"\n", name);

    D3D12_COMMAND_QUEUE_DESC queue_desc = {0};
    queue_desc.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    ID3D12CommandQueue *queue;
    CHECK(ID3D12Device_CreateCommandQueue(device, &queue_desc, &IID_ID3D12CommandQueue, (void **)&queue));

    DXGI_SWAP_CHAIN_DESC1 sd = {0};
    sd.Width = WIDTH;
    sd.Height = HEIGHT;
    sd.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.SampleDesc.Count = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.BufferCount = BUFFERS;
    sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    IDXGISwapChain1 *swapchain1;
    IDXGISwapChain3 *swapchain;
    CHECK(IDXGIFactory4_CreateSwapChainForHwnd(factory, (IUnknown *)queue, hwnd, &sd, NULL, NULL, &swapchain1));
    CHECK(IDXGISwapChain1_QueryInterface(swapchain1, &IID_IDXGISwapChain3, (void **)&swapchain));

    D3D12_DESCRIPTOR_HEAP_DESC heap_desc = {0};
    heap_desc.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
    heap_desc.NumDescriptors = BUFFERS;
    ID3D12DescriptorHeap *heap;
    CHECK(ID3D12Device_CreateDescriptorHeap(device, &heap_desc, &IID_ID3D12DescriptorHeap, (void **)&heap));
    UINT increment = ID3D12Device_GetDescriptorHandleIncrementSize(device, D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    D3D12_CPU_DESCRIPTOR_HANDLE base = ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart(heap);

    ID3D12Resource *buffers[BUFFERS];
    D3D12_CPU_DESCRIPTOR_HANDLE rtv[BUFFERS];
    for (int i = 0; i < BUFFERS; i++)
    {
        CHECK(IDXGISwapChain3_GetBuffer(swapchain, i, &IID_ID3D12Resource, (void **)&buffers[i]));
        rtv[i].ptr = base.ptr + (SIZE_T)i * increment;
        ID3D12Device_CreateRenderTargetView(device, buffers[i], NULL, rtv[i]);
    }

    ID3D12CommandAllocator *allocator;
    ID3D12GraphicsCommandList *list;
    ID3D12Fence *fence;
    CHECK(ID3D12Device_CreateCommandAllocator(device, D3D12_COMMAND_LIST_TYPE_DIRECT,
                                              &IID_ID3D12CommandAllocator, (void **)&allocator));
    CHECK(ID3D12Device_CreateCommandList(device, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator, NULL,
                                         &IID_ID3D12GraphicsCommandList, (void **)&list));
    CHECK(ID3D12GraphicsCommandList_Close(list));
    CHECK(ID3D12Device_CreateFence(device, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence));
    HANDLE fence_event = CreateEventW(NULL, FALSE, FALSE, NULL);
    UINT64 fence_value = 0;

    LARGE_INTEGER freq, start, end;
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&start);
    for (int i = 0; i < frames; i++)
    {
        MSG msg;
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) DispatchMessageW(&msg);
        UINT index = IDXGISwapChain3_GetCurrentBackBufferIndex(swapchain);
        CHECK(ID3D12CommandAllocator_Reset(allocator));
        CHECK(ID3D12GraphicsCommandList_Reset(list, allocator, NULL));
        transition(list, buffers[index], D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_RENDER_TARGET);
        float color[4] = { 0.1f, (i % 60) / 60.0f, 0.4f, 1.0f };
        ID3D12GraphicsCommandList_ClearRenderTargetView(list, rtv[index], color, 0, NULL);
        transition(list, buffers[index], D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PRESENT);
        CHECK(ID3D12GraphicsCommandList_Close(list));
        ID3D12CommandList *lists[] = { (ID3D12CommandList *)list };
        ID3D12CommandQueue_ExecuteCommandLists(queue, 1, lists);
        CHECK(IDXGISwapChain3_Present(swapchain, 0, 0));
        CHECK(ID3D12CommandQueue_Signal(queue, fence, ++fence_value));
        if (ID3D12Fence_GetCompletedValue(fence) < fence_value)
        {
            CHECK(ID3D12Fence_SetEventOnCompletion(fence, fence_value, fence_event));
            if (WaitForSingleObject(fence_event, 5000) != WAIT_OBJECT_0)
            {
                printf("FAIL GPU fence timeout at frame %d\n", i);
                return 1;
            }
        }
    }
    QueryPerformanceCounter(&end);
    printf("frames=%d fps=%.0f\n", frames, frames * (double)freq.QuadPart / (end.QuadPart - start.QuadPart));
    return 0;
}
