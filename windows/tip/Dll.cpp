// The COM server: the class factory, and registration as a Korean keyboard text service.
#include <cstdlib>
#include "TextService.h"
#include "resource.h"

#include <new>

namespace araso {

HINSTANCE g_instance = nullptr;
LONG g_references = 0;

namespace {

class ClassFactory final : public IClassFactory {
public:
    STDMETHODIMP QueryInterface(REFIID riid, void **object) override {
        if (!object) return E_INVALIDARG;
        if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, IID_IClassFactory)) {
            *object = static_cast<IClassFactory *>(this);
            AddRef();
            return S_OK;
        }
        *object = nullptr;
        return E_NOINTERFACE;
    }
    STDMETHODIMP_(ULONG) AddRef() override { DllAddRef(); return 2; }
    STDMETHODIMP_(ULONG) Release() override { DllRelease(); return 1; }

    STDMETHODIMP CreateInstance(IUnknown *outer, REFIID riid, void **object) override {
        if (!object) return E_INVALIDARG;
        *object = nullptr;
        if (outer) return CLASS_E_NOAGGREGATION;
        TextService *service = new (std::nothrow) TextService();
        if (!service) return E_OUTOFMEMORY;
        HRESULT hr = service->QueryInterface(riid, object);
        service->Release();
        return hr;
    }
    STDMETHODIMP LockServer(BOOL lock) override {
        if (lock) DllAddRef(); else DllRelease();
        return S_OK;
    }
};

ClassFactory g_factory;

std::wstring GuidString(const GUID &guid) {
    wchar_t text[64];
    StringFromGUID2(guid, text, 64);
    return text;
}

std::wstring ModulePath() {
    wchar_t path[MAX_PATH] = L"";
    GetModuleFileNameW(g_instance, path, MAX_PATH);
    return path;
}

bool SetValue(HKEY key, const wchar_t *name, const std::wstring &value) {
    return RegSetValueExW(key, name, 0, REG_SZ, reinterpret_cast<const BYTE *>(value.c_str()),
                          static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t))) == ERROR_SUCCESS;
}

/// HKLM\Software\Classes\CLSID\{…}\InprocServer32 = this DLL, apartment threaded.
bool RegisterServer() {
    std::wstring path = L"Software\\Classes\\CLSID\\" + GuidString(kClsidTextService);
    HKEY key = nullptr;
    if (RegCreateKeyExW(HKEY_LOCAL_MACHINE, path.c_str(), 0, nullptr, 0, KEY_WRITE, nullptr, &key, nullptr) != ERROR_SUCCESS) {
        return false;
    }
    SetValue(key, nullptr, L"Araso");
    HKEY server = nullptr;
    bool ok = RegCreateKeyExW(key, L"InprocServer32", 0, nullptr, 0, KEY_WRITE, nullptr, &server, nullptr) == ERROR_SUCCESS;
    if (ok) {
        ok = SetValue(server, nullptr, ModulePath()) && SetValue(server, L"ThreadingModel", L"Apartment");
        RegCloseKey(server);
    }
    RegCloseKey(key);
    return ok;
}

void UnregisterServer() {
    std::wstring path = L"Software\\Classes\\CLSID\\" + GuidString(kClsidTextService);
    RegDeleteTreeW(HKEY_LOCAL_MACHINE, path.c_str());
}

const GUID *const kCategories[] = {
    &kTfCatTipKeyboard,
    &kTfCatDisplayAttributeProvider,
    &kTfCatTipcapUIElementEnabled,
    &kTfCatTipcapInputModeCompartment,
    &kTfCatTipcapComless,
    &kTfCatTipcapImmersiveSupport,
    &kTfCatTipcapSystraySupport,
};

bool RegisterProfile() {
    std::wstring icon = ModulePath();
    std::wstring name = L"Araso";
    ITfInputProcessorProfileMgr *profiles = nullptr;
    HRESULT hr = CoCreateInstance(kClsidTfInputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER,
                                  kIID_ITfInputProcessorProfileMgr, reinterpret_cast<void **>(&profiles));
    if (FAILED(hr)) return false;
    // The icon is the first in the DLL (index 0).
    hr = profiles->RegisterProfile(kClsidTextService, kLangId, kGuidProfile, name.c_str(), static_cast<ULONG>(name.size()),
                                   icon.c_str(), static_cast<ULONG>(icon.size()), 0, nullptr, 0, TRUE, 0);
    profiles->Release();
    return SUCCEEDED(hr);
}

void UnregisterProfile() {
    ITfInputProcessorProfileMgr *profiles = nullptr;
    if (SUCCEEDED(CoCreateInstance(kClsidTfInputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER,
                                   kIID_ITfInputProcessorProfileMgr, reinterpret_cast<void **>(&profiles)))) {
        profiles->UnregisterProfile(kClsidTextService, kLangId, kGuidProfile, 0);
        profiles->Release();
    }
}

bool RegisterCategories(bool add) {
    ITfCategoryMgr *categories = nullptr;
    if (FAILED(CoCreateInstance(kClsidTfCategoryMgr, nullptr, CLSCTX_INPROC_SERVER, kIID_ITfCategoryMgr,
                                reinterpret_cast<void **>(&categories)))) return false;
    bool ok = true;
    for (const GUID *category : kCategories) {
        HRESULT hr = add ? categories->RegisterCategory(kClsidTextService, *category, kClsidTextService)
                         : categories->UnregisterCategory(kClsidTextService, *category, kClsidTextService);
        ok = ok && SUCCEEDED(hr);
    }
    categories->Release();
    return ok;
}

}  // namespace

}  // namespace araso

using namespace araso;

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        g_instance = instance;
        DisableThreadLibraryCalls(instance);
    }
    return TRUE;
}

extern "C" HRESULT __stdcall DllGetClassObject(REFCLSID clsid, REFIID riid, void **object) {
    if (!object) return E_INVALIDARG;
    *object = nullptr;
    if (!IsEqualCLSID(clsid, kClsidTextService)) return CLASS_E_CLASSNOTAVAILABLE;
    return g_factory.QueryInterface(riid, object);
}

extern "C" HRESULT __stdcall DllCanUnloadNow() { return g_references <= 0 ? S_OK : S_FALSE; }

extern "C" HRESULT __stdcall DllRegisterServer() {
    HRESULT init = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    bool ok = RegisterServer() && RegisterProfile() && RegisterCategories(true);
    if (SUCCEEDED(init)) CoUninitialize();
    if (!ok) {
        DllUnregisterServer();
        return SELFREG_E_CLASS;
    }
    return S_OK;
}

extern "C" HRESULT __stdcall DllUnregisterServer() {
    HRESULT init = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    RegisterCategories(false);
    UnregisterProfile();
    UnregisterServer();
    if (SUCCEEDED(init)) CoUninitialize();
    return S_OK;
}
