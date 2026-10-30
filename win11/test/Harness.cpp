// Harness - loads ForensicAidShell.dll without installing it and prints what the Windows 11 menu would show.
//
//   Harness.exe <dll> item|bg <path> [<path2>]      (two paths = multi-select)
//
// With FORENSICAID_SHELL_DRYRUN=1 the first visible item is invoked and its command line goes to dryrun.log.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wrl/client.h>
#include <cstdio>
#include <fcntl.h>
#include <io.h>
#include <vector>

using Microsoft::WRL::ComPtr;

static const CLSID CLSID_Item = { 0x7b3f1c52, 0x9a4e, 0x4d8b, { 0xb6, 0xe1, 0x2c, 0x5a, 0x9f, 0x0d, 0x3e, 0x71 } };
static const CLSID CLSID_Background = { 0x7b3f1c52, 0x9a4e, 0x4d8b, { 0xb6, 0xe1, 0x2c, 0x5a, 0x9f, 0x0d, 0x3e, 0x72 } };

typedef HRESULT(STDAPICALLTYPE* GetClassObjectFn)(REFCLSID, REFIID, void**);
typedef HRESULT(STDAPICALLTYPE* CanUnloadFn)();

static const wchar_t* StateName(EXPCMDSTATE s) { return (s & ECS_HIDDEN) ? L"HIDDEN" : (s & ECS_DISABLED) ? L"DISABLED" : L"ENABLED"; }

int wmain(int argc, wchar_t** argv) {
    _setmode(_fileno(stdout), _O_U8TEXT);
    if (argc < 4) { wprintf(L"usage: Harness <dll> item|bg <path> [<path2>]\n"); return 2; }
    if (FAILED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED))) return 3;

    HMODULE dll = LoadLibraryW(argv[1]);
    if (!dll) { wprintf(L"LoadLibrary failed: %lu\n", GetLastError()); return 4; }
    auto getClass = reinterpret_cast<GetClassObjectFn>(GetProcAddress(dll, "DllGetClassObject"));
    auto canUnload = reinterpret_cast<CanUnloadFn>(GetProcAddress(dll, "DllCanUnloadNow"));
    if (!getClass || !canUnload) { wprintf(L"exports missing\n"); return 5; }

    int rc = 0;
    {
        bool bg = wcscmp(argv[2], L"bg") == 0;
        ComPtr<IClassFactory> factory;
        HRESULT hr = getClass(bg ? CLSID_Background : CLSID_Item, IID_PPV_ARGS(&factory));
        ComPtr<IExplorerCommand> root;
        if (SUCCEEDED(hr)) hr = factory->CreateInstance(nullptr, IID_PPV_ARGS(&root));
        if (FAILED(hr)) { wprintf(L"CreateInstance failed: 0x%08X\n", hr); return 6; }

        ComPtr<IShellItemArray> items;
        if (argc == 4) {
            ComPtr<IShellItem> item;
            hr = SHCreateItemFromParsingName(argv[3], nullptr, IID_PPV_ARGS(&item));
            if (SUCCEEDED(hr)) hr = SHCreateShellItemArrayFromShellItem(item.Get(), IID_PPV_ARGS(&items));
        } else {
            std::vector<PIDLIST_ABSOLUTE> pidls;
            for (int i = 3; i < argc; ++i) {
                PIDLIST_ABSOLUTE p = nullptr;
                if (SUCCEEDED(SHParseDisplayName(argv[i], nullptr, &p, 0, nullptr))) pidls.push_back(p);
            }
            hr = SHCreateShellItemArrayFromIDLists(static_cast<UINT>(pidls.size()), const_cast<PCIDLIST_ABSOLUTE_ARRAY>(reinterpret_cast<PIDLIST_ABSOLUTE*>(pidls.data())), &items);
            for (auto p : pidls) CoTaskMemFree(p);
        }
        if (FAILED(hr)) { wprintf(L"shell item array failed: 0x%08X\n", hr); return 7; }

        PWSTR title = nullptr, icon = nullptr;
        root->GetTitle(items.Get(), &title);
        root->GetIcon(items.Get(), &icon);
        EXPCMDSTATE state = ECS_HIDDEN;
        root->GetState(items.Get(), TRUE, &state);
        EXPCMDFLAGS flags = 0;
        root->GetFlags(&flags);
        wprintf(L"ROOT  %ls  [%ls]  flags=0x%X  icon=%ls\n", title ? title : L"?", StateName(state), flags, icon ? icon : L"-");
        CoTaskMemFree(title);
        CoTaskMemFree(icon);

        if (!(state & ECS_HIDDEN)) {
            ComPtr<IEnumExplorerCommand> e;
            if (SUCCEEDED(root->EnumSubCommands(&e))) {
                bool invoked = false;
                ComPtr<IExplorerCommand> sub;
                while (e->Next(1, &sub, nullptr) == S_OK) {
                    PWSTR t = nullptr;
                    sub->GetTitle(items.Get(), &t);
                    EXPCMDSTATE s = ECS_HIDDEN;
                    sub->GetState(items.Get(), TRUE, &s);
                    EXPCMDFLAGS f = 0;
                    sub->GetFlags(&f);
                    wprintf(L"  - %-40ls [%ls]%ls\n", t ? t : L"?", StateName(s), (f & ECF_SEPARATORBEFORE) ? L" (separator)" : L"");
                    CoTaskMemFree(t);
                    if (!invoked && !(s & ECS_HIDDEN) && GetEnvironmentVariableW(L"FORENSICAID_SHELL_DRYRUN", nullptr, 0) > 0) {
                        hr = sub->Invoke(items.Get(), nullptr);
                        wprintf(L"    invoked -> 0x%08X\n", hr);
                        invoked = true;
                    }
                    sub.Reset();
                }
            }
        }
    }
    wprintf(L"DllCanUnloadNow after release: %ls\n", canUnload() == S_OK ? L"S_OK" : L"S_FALSE (leak)");
    CoUninitialize();
    return rc;
}
