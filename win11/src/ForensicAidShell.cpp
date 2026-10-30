// ForensicAidShell - puts the ForensicAid submenu into the Windows 11 top-level context menu.
//
// Explorer only shows IExplorerCommand handlers from packaged COM servers in the new menu, so this DLL
// is registered through a sparse package (see ..\package\AppxManifest.xml). It holds no menu logic of
// its own: ForensicAid.ps1 writes menu.json next to this DLL and every item just launches its command.
//
// Two classes: CLSID_Item for files / folders / drives, CLSID_Background for a folder background.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <shlwapi.h>
#include <wrl/client.h>

#include <atomic>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <utility>
#include <vector>

using Microsoft::WRL::ComPtr;

// {7B3F1C52-9A4E-4D8B-B6E1-2C5A9F0D3E71}
static const CLSID CLSID_Item = { 0x7b3f1c52, 0x9a4e, 0x4d8b, { 0xb6, 0xe1, 0x2c, 0x5a, 0x9f, 0x0d, 0x3e, 0x71 } };
// {7B3F1C52-9A4E-4D8B-B6E1-2C5A9F0D3E72}
static const CLSID CLSID_Background = { 0x7b3f1c52, 0x9a4e, 0x4d8b, { 0xb6, 0xe1, 0x2c, 0x5a, 0x9f, 0x0d, 0x3e, 0x72 } };

static HMODULE g_module = nullptr;
static std::atomic<long> g_objects{ 0 };

// ------------------------------------------------------------------------------------------------
// Minimal JSON reader (objects, arrays, strings, bools, numbers, null) - enough for menu.json.

struct JValue {
    enum Kind { Null, Bool, Num, Str, Arr, Obj } kind = Null;
    bool b = false;
    std::wstring s;
    std::vector<JValue> a;
    std::vector<std::pair<std::wstring, JValue>> o;

    const JValue* Get(const wchar_t* key) const {
        if (kind != Obj) return nullptr;
        for (const auto& kv : o) if (kv.first == key) return &kv.second;
        return nullptr;
    }
};

class JParser {
public:
    JParser(const char* p, const char* e) : p_(p), e_(e) {}

    bool ParseDocument(JValue& v) {
        if (!Parse(v)) return false;
        Ws();
        return p_ == e_;
    }

private:
    const char* p_;
    const char* e_;
    int depth_ = 0;

    void Ws() { while (p_ < e_ && (*p_ == ' ' || *p_ == '\t' || *p_ == '\r' || *p_ == '\n')) ++p_; }

    bool Lit(const char* lit) {
        size_t n = strlen(lit);
        if (static_cast<size_t>(e_ - p_) < n || memcmp(p_, lit, n) != 0) return false;
        p_ += n;
        return true;
    }

    bool Parse(JValue& v) {
        Ws();
        if (p_ >= e_ || ++depth_ > 32) return false;
        bool ok = false;
        switch (*p_) {
        case '{': ok = ParseObject(v); break;
        case '[': ok = ParseArray(v); break;
        case '"': v.kind = JValue::Str; ok = ParseString(v.s); break;
        case 't': v.kind = JValue::Bool; v.b = true; ok = Lit("true"); break;
        case 'f': v.kind = JValue::Bool; v.b = false; ok = Lit("false"); break;
        case 'n': v.kind = JValue::Null; ok = Lit("null"); break;
        default:
            v.kind = JValue::Num;
            while (p_ < e_ && (strchr("+-0123456789.eE", *p_) != nullptr)) { v.s += static_cast<wchar_t>(*p_++); ok = true; }
        }
        --depth_;
        return ok;
    }

    bool ParseObject(JValue& v) {
        v.kind = JValue::Obj;
        ++p_;
        Ws();
        if (p_ < e_ && *p_ == '}') { ++p_; return true; }
        for (;;) {
            Ws();
            std::wstring key;
            if (p_ >= e_ || *p_ != '"' || !ParseString(key)) return false;
            Ws();
            if (p_ >= e_ || *p_ != ':') return false;
            ++p_;
            JValue child;
            if (!Parse(child)) return false;
            v.o.emplace_back(std::move(key), std::move(child));
            Ws();
            if (p_ < e_ && *p_ == ',') { ++p_; continue; }
            if (p_ < e_ && *p_ == '}') { ++p_; return true; }
            return false;
        }
    }

    bool ParseArray(JValue& v) {
        v.kind = JValue::Arr;
        ++p_;
        Ws();
        if (p_ < e_ && *p_ == ']') { ++p_; return true; }
        for (;;) {
            JValue child;
            if (!Parse(child)) return false;
            v.a.push_back(std::move(child));
            Ws();
            if (p_ < e_ && *p_ == ',') { ++p_; continue; }
            if (p_ < e_ && *p_ == ']') { ++p_; return true; }
            return false;
        }
    }

    static void AppendUtf8(std::string& out, unsigned cp) {
        if (cp < 0x80) out += static_cast<char>(cp);
        else if (cp < 0x800) { out += static_cast<char>(0xC0 | (cp >> 6)); out += static_cast<char>(0x80 | (cp & 0x3F)); }
        else if (cp < 0x10000) { out += static_cast<char>(0xE0 | (cp >> 12)); out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F)); out += static_cast<char>(0x80 | (cp & 0x3F)); }
        else { out += static_cast<char>(0xF0 | (cp >> 18)); out += static_cast<char>(0x80 | ((cp >> 12) & 0x3F)); out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F)); out += static_cast<char>(0x80 | (cp & 0x3F)); }
    }

    bool Hex4(unsigned& cp) {
        if (e_ - p_ < 4) return false;
        cp = 0;
        for (int i = 0; i < 4; ++i, ++p_) {
            char c = *p_;
            cp <<= 4;
            if (c >= '0' && c <= '9') cp |= c - '0';
            else if (c >= 'a' && c <= 'f') cp |= c - 'a' + 10;
            else if (c >= 'A' && c <= 'F') cp |= c - 'A' + 10;
            else return false;
        }
        return true;
    }

    // Unescapes into UTF-8, then converts to UTF-16 once.
    bool ParseString(std::wstring& out) {
        ++p_;
        std::string raw;
        while (p_ < e_ && *p_ != '"') {
            char c = *p_++;
            if (c != '\\') { raw += c; continue; }
            if (p_ >= e_) return false;
            char esc = *p_++;
            switch (esc) {
            case '"': raw += '"'; break;
            case '\\': raw += '\\'; break;
            case '/': raw += '/'; break;
            case 'b': raw += '\b'; break;
            case 'f': raw += '\f'; break;
            case 'n': raw += '\n'; break;
            case 'r': raw += '\r'; break;
            case 't': raw += '\t'; break;
            case 'u': {
                unsigned cp;
                if (!Hex4(cp)) return false;
                if (cp >= 0xD800 && cp <= 0xDBFF) {
                    unsigned lo;
                    if (e_ - p_ >= 6 && p_[0] == '\\' && p_[1] == 'u') {
                        p_ += 2;
                        if (!Hex4(lo)) return false;
                        cp = (lo >= 0xDC00 && lo <= 0xDFFF) ? 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00) : 0xFFFD;
                    } else {
                        cp = 0xFFFD;
                    }
                } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                    cp = 0xFFFD;
                }
                AppendUtf8(raw, cp);
                break;
            }
            default: return false;
            }
        }
        if (p_ >= e_) return false;
        ++p_;
        out.clear();
        if (raw.empty()) return true;
        int n = MultiByteToWideChar(CP_UTF8, 0, raw.data(), static_cast<int>(raw.size()), nullptr, 0);
        if (n <= 0) return false;
        out.resize(n);
        MultiByteToWideChar(CP_UTF8, 0, raw.data(), static_cast<int>(raw.size()), &out[0], n);
        return true;
    }
};

// ------------------------------------------------------------------------------------------------
// menu.json model, cached until the file changes.

struct MenuItem {
    std::wstring id, title, icon, command;
    std::vector<std::wstring> scopes, ext, names, prefixes, exclude;   // match lists are lower-case
    int group = 0;                  // separators are drawn where the group of visible items changes
    bool separatorBefore = false;   // fallback when the selection is unknown
    bool hidden = false;
};

struct Menu {
    std::wstring title = L"ForensicAid";
    std::wstring icon;
    std::vector<MenuItem> items;
};

static std::wstring Lower(const std::wstring& s) {
    if (s.empty()) return s;
    std::wstring out(s.size(), L'\0');
    int n = LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_LOWERCASE, s.c_str(), static_cast<int>(s.size()),
                          &out[0], static_cast<int>(out.size()), nullptr, nullptr, 0);
    if (n <= 0) return s;
    out.resize(n);
    return out;
}

static std::wstring ModuleDir() {
    std::wstring path(MAX_PATH, L'\0');
    for (;;) {
        DWORD n = GetModuleFileNameW(g_module, &path[0], static_cast<DWORD>(path.size()));
        if (n == 0) return L"";
        if (n < path.size()) { path.resize(n); break; }
        path.resize(path.size() * 2);
    }
    size_t slash = path.find_last_of(L'\\');
    return slash == std::wstring::npos ? L"" : path.substr(0, slash);
}

static std::wstring JStr(const JValue& obj, const wchar_t* key) {
    const JValue* v = obj.Get(key);
    return (v && v->kind == JValue::Str) ? v->s : L"";
}

static bool JBool(const JValue& obj, const wchar_t* key) {
    const JValue* v = obj.Get(key);
    return v && v->kind == JValue::Bool && v->b;
}

static std::vector<std::wstring> JList(const JValue& obj, const wchar_t* key, bool lower) {
    std::vector<std::wstring> out;
    const JValue* v = obj.Get(key);
    if (!v) return out;
    if (v->kind == JValue::Str) { out.push_back(lower ? Lower(v->s) : v->s); return out; }   // ConvertTo-Json unwraps 1-element arrays
    if (v->kind != JValue::Arr) return out;
    for (const auto& e : v->a) if (e.kind == JValue::Str) out.push_back(lower ? Lower(e.s) : e.s);
    return out;
}

static std::shared_ptr<const Menu> ParseMenu(const std::string& bytes) {
    const char* p = bytes.data();
    const char* e = p + bytes.size();
    if (bytes.size() >= 3 && memcmp(p, "\xEF\xBB\xBF", 3) == 0) p += 3;
    JValue root;
    if (!JParser(p, e).ParseDocument(root) || root.kind != JValue::Obj) return nullptr;

    auto menu = std::make_shared<Menu>();
    std::wstring t = JStr(root, L"title");
    if (!t.empty()) menu->title = t;
    menu->icon = JStr(root, L"icon");
    const JValue* items = root.Get(L"items");
    std::vector<const JValue*> list;
    if (items && items->kind == JValue::Obj) list.push_back(items);   // a single item, unwrapped by ConvertTo-Json
    if (items && items->kind == JValue::Arr) for (const auto& it : items->a) list.push_back(&it);
    {
        for (const JValue* pit : list) {
            const JValue& it = *pit;
            if (it.kind != JValue::Obj) continue;
            MenuItem m;
            m.id = JStr(it, L"id");
            m.title = JStr(it, L"title");
            m.icon = JStr(it, L"icon");
            m.command = JStr(it, L"command");
            m.scopes = JList(it, L"scopes", false);
            m.ext = JList(it, L"ext", true);
            m.names = JList(it, L"names", true);
            m.prefixes = JList(it, L"prefixes", true);
            m.exclude = JList(it, L"excludeNames", true);
            m.separatorBefore = JBool(it, L"separatorBefore");
            if (const JValue* g = it.Get(L"group")) if (g->kind == JValue::Num) m.group = _wtoi(g->s.c_str());
            m.hidden = JBool(it, L"hidden");
            if (!m.title.empty() && !m.command.empty()) menu->items.push_back(std::move(m));
        }
    }
    return menu;
}

static std::mutex g_menuLock;
static std::shared_ptr<const Menu> g_menu;
static FILETIME g_menuTime = {};
static ULONGLONG g_menuSize = ~0ULL;

static std::shared_ptr<const Menu> LoadMenu() {
    std::wstring file = ModuleDir() + L"\\menu.json";
    WIN32_FILE_ATTRIBUTE_DATA fad;
    if (!GetFileAttributesExW(file.c_str(), GetFileExInfoStandard, &fad)) return nullptr;
    ULONGLONG size = (static_cast<ULONGLONG>(fad.nFileSizeHigh) << 32) | fad.nFileSizeLow;

    std::lock_guard<std::mutex> lock(g_menuLock);
    if (size == g_menuSize && CompareFileTime(&fad.ftLastWriteTime, &g_menuTime) == 0) return g_menu;

    std::shared_ptr<const Menu> menu;
    if (size > 0 && size < 4 * 1024 * 1024) {
        HANDLE h = CreateFileW(file.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                               nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (h != INVALID_HANDLE_VALUE) {
            std::string bytes(static_cast<size_t>(size), '\0');
            DWORD read = 0;
            if (ReadFile(h, &bytes[0], static_cast<DWORD>(size), &read, nullptr) && read == size) menu = ParseMenu(bytes);
            CloseHandle(h);
        }
    }
    g_menu = menu;           // a broken file is cached too, until it changes again
    g_menuTime = fad.ftLastWriteTime;
    g_menuSize = size;
    return menu;
}

// ------------------------------------------------------------------------------------------------
// Selection

enum class Kind { File, Dir, Background };

static const wchar_t* ScopeName(Kind k) {
    return k == Kind::File ? L"File" : (k == Kind::Dir ? L"Dir" : L"Background");
}

struct Selection {
    bool ok = false;
    Kind kind = Kind::File;
    std::wstring path;
    std::wstring nameLower;
};

static std::wstring FolderFromSite(IUnknown* site) {
    if (!site) return L"";
    ComPtr<IServiceProvider> sp;
    ComPtr<IShellBrowser> browser;
    ComPtr<IShellView> view;
    ComPtr<IFolderView> folderView;
    ComPtr<IPersistFolder2> folder;
    if (FAILED(site->QueryInterface(IID_PPV_ARGS(&sp)))) return L"";
    if (FAILED(sp->QueryService(SID_STopLevelBrowser, IID_PPV_ARGS(&browser)))) return L"";
    if (FAILED(browser->QueryActiveShellView(&view)) || !view) return L"";
    if (FAILED(view.As(&folderView))) return L"";
    if (FAILED(folderView->GetFolder(IID_PPV_ARGS(&folder)))) return L"";
    PIDLIST_ABSOLUTE pidl = nullptr;
    if (FAILED(folder->GetCurFolder(&pidl)) || !pidl) return L"";
    PWSTR name = nullptr;
    std::wstring out;
    if (SUCCEEDED(SHGetNameFromIDList(pidl, SIGDN_FILESYSPATH, &name))) { out = name; CoTaskMemFree(name); }
    CoTaskMemFree(pidl);
    return out;
}

static Selection GetSelection(IShellItemArray* items, bool background, IUnknown* site) {
    Selection sel;
    ComPtr<IShellItem> item;
    if (items) {
        DWORD count = 0;
        if (FAILED(items->GetCount(&count)) || count != 1) return sel;   // single selection only, like the classic menu
        if (FAILED(items->GetItemAt(0, &item))) return sel;
    }

    if (item) {
        PWSTR path = nullptr;
        if (FAILED(item->GetDisplayName(SIGDN_FILESYSPATH, &path)) || !path) return sel;   // not a file system item
        sel.path = path;
        CoTaskMemFree(path);
        SFGAOF attrs = 0;
        item->GetAttributes(SFGAO_FOLDER | SFGAO_STREAM, &attrs);
        bool folder = (attrs & SFGAO_FOLDER) && !(attrs & SFGAO_STREAM);   // .zip is FOLDER|STREAM -> a file
        sel.kind = background ? Kind::Background : (folder ? Kind::Dir : Kind::File);
    } else if (background) {
        sel.path = FolderFromSite(site);
        sel.kind = Kind::Background;
    }
    if (sel.path.empty()) return sel;

    const wchar_t* name = PathFindFileNameW(sel.path.c_str());
    sel.nameLower = Lower(name ? name : L"");
    sel.ok = true;
    return sel;
}

static bool Contains(const std::vector<std::wstring>& list, const std::wstring& v) {
    for (const auto& x : list) if (x == v) return true;
    return false;
}

static bool Matches(const MenuItem& it, const Selection& sel) {
    if (!sel.ok || !Contains(it.scopes, ScopeName(sel.kind))) return false;
    if (sel.kind != Kind::File) return true;
    const std::wstring& n = sel.nameLower;
    if (Contains(it.exclude, n)) return false;
    if (it.ext.empty() && it.names.empty() && it.prefixes.empty()) return true;
    for (const auto& x : it.ext) if (n.size() >= x.size() && n.compare(n.size() - x.size(), x.size(), x) == 0) return true;
    if (Contains(it.names, n)) return true;
    for (const auto& x : it.prefixes) if (n.compare(0, x.size(), x) == 0) return true;
    return false;
}

// ------------------------------------------------------------------------------------------------
// Launching

static bool DryRun(const std::wstring& dir) {
    wchar_t buf[8];
    if (GetEnvironmentVariableW(L"FORENSICAID_SHELL_DRYRUN", buf, ARRAYSIZE(buf)) > 0) return true;
    return GetFileAttributesW((dir + L"\\dryrun.flag").c_str()) != INVALID_FILE_ATTRIBUTES;
}

static void AppendLog(const std::wstring& file, const std::wstring& line) {
    std::wstring text = line + L"\r\n";
    int n = WideCharToMultiByte(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    if (n <= 0) return;
    std::string utf8(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()), &utf8[0], n, nullptr, nullptr);
    HANDLE h = CreateFileW(file.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return;
    DWORD written = 0;
    WriteFile(h, utf8.data(), static_cast<DWORD>(utf8.size()), &written, nullptr);
    CloseHandle(h);
}

static HRESULT Launch(const MenuItem& it, const std::wstring& path) {
    // Single pass so a '%1' inside the path itself is never expanded again.
    std::wstring cmd;
    cmd.reserve(it.command.size() + path.size());
    for (size_t i = 0; i < it.command.size(); ++i) {
        if (it.command[i] == L'%' && i + 1 < it.command.size() && it.command[i + 1] == L'1') { cmd += path; ++i; }
        else cmd += it.command[i];
    }

    std::wstring dir = ModuleDir();
    OutputDebugStringW((L"ForensicAidShell: " + cmd + L"\n").c_str());
    if (DryRun(dir)) {
        AppendLog(dir + L"\\dryrun.log", cmd);
        return S_OK;
    }

    STARTUPINFOW si = { sizeof(si) };
    DWORD flags = CREATE_NEW_CONSOLE;
    if (it.hidden) {
        si.dwFlags = STARTF_USESHOWWINDOW;
        si.wShowWindow = SW_HIDE;
        flags = CREATE_NO_WINDOW;
    }
    std::vector<wchar_t> buf(cmd.begin(), cmd.end());
    buf.push_back(L'\0');
    PROCESS_INFORMATION pi = {};
    if (!CreateProcessW(nullptr, buf.data(), nullptr, nullptr, FALSE, flags, nullptr,
                        dir.empty() ? nullptr : dir.c_str(), &si, &pi)) {
        return HRESULT_FROM_WIN32(GetLastError());
    }
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return S_OK;
}

// ------------------------------------------------------------------------------------------------
// COM objects

class ObjectCount {
protected:
    ObjectCount() { ++g_objects; }
    ~ObjectCount() { --g_objects; }
};

#define FA_IUNKNOWN_REFCOUNT                                                        \
    IFACEMETHODIMP_(ULONG) AddRef() override { return InterlockedIncrement(&ref_); } \
    IFACEMETHODIMP_(ULONG) Release() override {                                     \
        long r = InterlockedDecrement(&ref_);                                       \
        if (r == 0) delete this;                                                    \
        return r;                                                                   \
    }

class SubCommand final : public IExplorerCommand, ObjectCount {
public:
    SubCommand(MenuItem item, Kind kind, ComPtr<IUnknown> site) : item_(std::move(item)), kind_(kind), site_(std::move(site)) {}

    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
        if (!ppv) return E_POINTER;
        if (riid == IID_IUnknown || riid == IID_IExplorerCommand) { *ppv = static_cast<IExplorerCommand*>(this); AddRef(); return S_OK; }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    FA_IUNKNOWN_REFCOUNT

    IFACEMETHODIMP GetTitle(IShellItemArray*, LPWSTR* name) override { return SHStrDupW(item_.title.c_str(), name); }
    IFACEMETHODIMP GetIcon(IShellItemArray*, LPWSTR* icon) override {
        *icon = nullptr;
        return item_.icon.empty() ? E_NOTIMPL : SHStrDupW(item_.icon.c_str(), icon);
    }
    IFACEMETHODIMP GetToolTip(IShellItemArray*, LPWSTR* tip) override { *tip = nullptr; return E_NOTIMPL; }
    IFACEMETHODIMP GetCanonicalName(GUID* guid) override { *guid = GUID_NULL; return E_NOTIMPL; }
    IFACEMETHODIMP GetState(IShellItemArray* items, BOOL, EXPCMDSTATE* state) override {
        try {
            *state = Matches(item_, GetSelection(items, kind_ == Kind::Background, site_.Get())) ? ECS_ENABLED : ECS_HIDDEN;
            return S_OK;
        } catch (...) { *state = ECS_HIDDEN; return S_OK; }
    }
    IFACEMETHODIMP Invoke(IShellItemArray* items, IBindCtx*) override {
        try {
            Selection sel = GetSelection(items, kind_ == Kind::Background, site_.Get());
            if (!sel.ok) return E_FAIL;
            return Launch(item_, sel.path);
        } catch (...) { return E_FAIL; }
    }
    IFACEMETHODIMP GetFlags(EXPCMDFLAGS* flags) override {
        *flags = item_.separatorBefore ? ECF_SEPARATORBEFORE : ECF_DEFAULT;
        return S_OK;
    }
    IFACEMETHODIMP EnumSubCommands(IEnumExplorerCommand** e) override { *e = nullptr; return E_NOTIMPL; }

private:
    ~SubCommand() = default;
    long ref_ = 1;
    MenuItem item_;
    Kind kind_;
    ComPtr<IUnknown> site_;
};

class CommandEnum final : public IEnumExplorerCommand, ObjectCount {
public:
    explicit CommandEnum(std::vector<ComPtr<IExplorerCommand>> cmds, ULONG pos = 0) : cmds_(std::move(cmds)), pos_(pos) {}

    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
        if (!ppv) return E_POINTER;
        if (riid == IID_IUnknown || riid == IID_IEnumExplorerCommand) { *ppv = static_cast<IEnumExplorerCommand*>(this); AddRef(); return S_OK; }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    FA_IUNKNOWN_REFCOUNT

    IFACEMETHODIMP Next(ULONG celt, IExplorerCommand** out, ULONG* fetched) override {
        if (!out || (celt > 1 && !fetched)) return E_POINTER;
        ULONG n = 0;
        while (n < celt && pos_ < cmds_.size()) {
            cmds_[pos_].CopyTo(&out[n]);
            ++n;
            ++pos_;
        }
        if (fetched) *fetched = n;
        return n == celt ? S_OK : S_FALSE;
    }
    IFACEMETHODIMP Skip(ULONG celt) override {
        ULONG left = static_cast<ULONG>(cmds_.size()) - pos_;
        ULONG n = celt < left ? celt : left;
        pos_ += n;
        return n == celt ? S_OK : S_FALSE;
    }
    IFACEMETHODIMP Reset() override { pos_ = 0; return S_OK; }
    IFACEMETHODIMP Clone(IEnumExplorerCommand** e) override {
        if (!e) return E_POINTER;
        *e = new (std::nothrow) CommandEnum(cmds_, pos_);
        return *e ? S_OK : E_OUTOFMEMORY;
    }

private:
    ~CommandEnum() = default;
    long ref_ = 1;
    std::vector<ComPtr<IExplorerCommand>> cmds_;
    ULONG pos_;
};

class RootCommand final : public IExplorerCommand, public IObjectWithSite, ObjectCount {
public:
    explicit RootCommand(Kind kind) : kind_(kind) {}

    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
        if (!ppv) return E_POINTER;
        if (riid == IID_IUnknown || riid == IID_IExplorerCommand) *ppv = static_cast<IExplorerCommand*>(this);
        else if (riid == IID_IObjectWithSite) *ppv = static_cast<IObjectWithSite*>(this);
        else { *ppv = nullptr; return E_NOINTERFACE; }
        AddRef();
        return S_OK;
    }
    FA_IUNKNOWN_REFCOUNT

    // IObjectWithSite - needed to find the folder for a background click.
    IFACEMETHODIMP SetSite(IUnknown* site) override { site_ = site; return S_OK; }
    IFACEMETHODIMP GetSite(REFIID riid, void** ppv) override {
        if (!ppv) return E_POINTER;
        *ppv = nullptr;
        return site_ ? site_->QueryInterface(riid, ppv) : E_FAIL;
    }

    IFACEMETHODIMP GetTitle(IShellItemArray*, LPWSTR* name) override {
        try {
            auto menu = LoadMenu();
            return SHStrDupW(menu ? menu->title.c_str() : L"ForensicAid", name);
        } catch (...) { return E_FAIL; }
    }
    IFACEMETHODIMP GetIcon(IShellItemArray*, LPWSTR* icon) override {
        *icon = nullptr;
        try {
            auto menu = LoadMenu();
            if (!menu || menu->icon.empty()) return E_NOTIMPL;
            return SHStrDupW(menu->icon.c_str(), icon);
        } catch (...) { return E_FAIL; }
    }
    IFACEMETHODIMP GetToolTip(IShellItemArray*, LPWSTR* tip) override { *tip = nullptr; return E_NOTIMPL; }
    IFACEMETHODIMP GetCanonicalName(GUID* guid) override { *guid = kind_ == Kind::Background ? CLSID_Background : CLSID_Item; return S_OK; }

    IFACEMETHODIMP GetState(IShellItemArray* items, BOOL, EXPCMDSTATE* state) override {
        *state = ECS_HIDDEN;
        try {
            auto menu = LoadMenu();
            if (!menu) return S_OK;
            Selection sel = GetSelection(items, kind_ == Kind::Background, site_.Get());
            for (const auto& it : menu->items) {
                if (Matches(it, sel)) { *state = ECS_ENABLED; break; }
            }
            std::lock_guard<std::mutex> lock(selLock_);
            lastSel_ = sel;
        } catch (...) { }
        return S_OK;
    }
    IFACEMETHODIMP Invoke(IShellItemArray*, IBindCtx*) override { return E_NOTIMPL; }
    IFACEMETHODIMP GetFlags(EXPCMDFLAGS* flags) override { *flags = ECF_HASSUBCOMMANDS; return S_OK; }

    IFACEMETHODIMP EnumSubCommands(IEnumExplorerCommand** e) override {
        if (!e) return E_POINTER;
        *e = nullptr;
        try {
            auto menu = LoadMenu();
            if (!menu) return E_FAIL;
            Selection sel;
            { std::lock_guard<std::mutex> lock(selLock_); sel = lastSel_; }
            std::vector<ComPtr<IExplorerCommand>> cmds;
            bool first = true;
            int lastGroup = 0;
            for (const auto& it : menu->items) {
                // Filter with the selection seen in GetState when we have it; each item re-checks in its own GetState.
                bool show = sel.ok ? Matches(it, sel)
                          : kind_ == Kind::Background ? Contains(it.scopes, L"Background")
                          : Contains(it.scopes, L"File") || Contains(it.scopes, L"Dir");
                if (!show) continue;
                MenuItem item = it;
                if (sel.ok) item.separatorBefore = !first && it.group != lastGroup;
                first = false;
                lastGroup = it.group;
                ComPtr<IExplorerCommand> cmd;
                cmd.Attach(new SubCommand(std::move(item), kind_, site_));
                cmds.push_back(std::move(cmd));
            }
            *e = new CommandEnum(std::move(cmds));
            return S_OK;
        } catch (...) { return E_OUTOFMEMORY; }
    }

private:
    ~RootCommand() = default;
    long ref_ = 1;
    Kind kind_;
    ComPtr<IUnknown> site_;
    std::mutex selLock_;
    Selection lastSel_;
};

class ClassFactory final : public IClassFactory, ObjectCount {
public:
    explicit ClassFactory(Kind kind) : kind_(kind) {}

    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
        if (!ppv) return E_POINTER;
        if (riid == IID_IUnknown || riid == IID_IClassFactory) { *ppv = static_cast<IClassFactory*>(this); AddRef(); return S_OK; }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    FA_IUNKNOWN_REFCOUNT

    IFACEMETHODIMP CreateInstance(IUnknown* outer, REFIID riid, void** ppv) override {
        if (!ppv) return E_POINTER;
        *ppv = nullptr;
        if (outer) return CLASS_E_NOAGGREGATION;
        RootCommand* cmd = new (std::nothrow) RootCommand(kind_);
        if (!cmd) return E_OUTOFMEMORY;
        HRESULT hr = cmd->QueryInterface(riid, ppv);
        cmd->Release();
        return hr;
    }
    IFACEMETHODIMP LockServer(BOOL lock) override {
        if (lock) ++g_objects; else --g_objects;
        return S_OK;
    }

private:
    ~ClassFactory() = default;
    long ref_ = 1;
    Kind kind_;
};

// ------------------------------------------------------------------------------------------------
// DLL exports

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        g_module = module;
        DisableThreadLibraryCalls(module);
    }
    return TRUE;
}

STDAPI DllGetClassObject(REFCLSID clsid, REFIID riid, void** ppv) {
    if (!ppv) return E_POINTER;
    *ppv = nullptr;
    Kind kind;
    if (clsid == CLSID_Item) kind = Kind::File;
    else if (clsid == CLSID_Background) kind = Kind::Background;
    else return CLASS_E_CLASSNOTAVAILABLE;
    ClassFactory* f = new (std::nothrow) ClassFactory(kind);
    if (!f) return E_OUTOFMEMORY;
    HRESULT hr = f->QueryInterface(riid, ppv);
    f->Release();
    return hr;
}

STDAPI DllCanUnloadNow() {
    return g_objects == 0 ? S_OK : S_FALSE;
}
