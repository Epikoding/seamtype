#include "DisplayAttributes.h"

#include <new>

namespace araso {

namespace {

TF_DISPLAYATTRIBUTE Attribute(TF_DA_LINESTYLE line, BOOL bold, TF_DA_ATTR_INFO info) {
    TF_DISPLAYATTRIBUTE attribute = {};
    attribute.crText.type = TF_CT_NONE;
    attribute.crBk.type = TF_CT_NONE;
    attribute.lsStyle = line;
    attribute.fBoldLine = bold;
    attribute.crLine.type = TF_CT_NONE;
    attribute.bAttr = info;
    return attribute;
}

}  // namespace

DisplayAttributeInfo::DisplayAttributeInfo(const GUID &guid, const wchar_t *description, TF_DISPLAYATTRIBUTE attribute)
    : guid_(guid), description_(description), attribute_(attribute) {
    DllAddRef();
}

DisplayAttributeInfo::~DisplayAttributeInfo() { DllRelease(); }

DisplayAttributeInfo *DisplayAttributeInfo::At(ULONG index) {
    switch (index) {
    case 0: return new (std::nothrow) DisplayAttributeInfo(kGuidAttrInput, L"Araso: word being typed",
                                                           Attribute(TF_LS_SOLID, FALSE, TF_ATTR_INPUT));
    case 1: return new (std::nothrow) DisplayAttributeInfo(kGuidAttrConverted, L"Araso: reading being converted",
                                                           Attribute(TF_LS_SOLID, FALSE, TF_ATTR_CONVERTED));
    case 2: return new (std::nothrow) DisplayAttributeInfo(kGuidAttrTarget, L"Araso: clause being converted",
                                                           Attribute(TF_LS_SOLID, TRUE, TF_ATTR_TARGET_CONVERTED));
    default: return nullptr;
    }
}

DisplayAttributeInfo *DisplayAttributeInfo::For(REFGUID guid) {
    for (ULONG k = 0; k < kCount; k++) {
        DisplayAttributeInfo *info = At(k);
        if (!info) return nullptr;
        if (IsEqualGUID(info->guid_, guid)) return info;
        info->Release();
    }
    return nullptr;
}

STDMETHODIMP DisplayAttributeInfo::QueryInterface(REFIID riid, void **object) {
    if (!object) return E_INVALIDARG;
    if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, IID_ITfDisplayAttributeInfo)) {
        *object = static_cast<ITfDisplayAttributeInfo *>(this);
        AddRef();
        return S_OK;
    }
    *object = nullptr;
    return E_NOINTERFACE;
}

STDMETHODIMP_(ULONG) DisplayAttributeInfo::AddRef() { return InterlockedIncrement(&references_); }

STDMETHODIMP_(ULONG) DisplayAttributeInfo::Release() {
    LONG count = InterlockedDecrement(&references_);
    if (!count) delete this;
    return count;
}

STDMETHODIMP DisplayAttributeInfo::GetGUID(GUID *guid) {
    if (!guid) return E_INVALIDARG;
    *guid = guid_;
    return S_OK;
}

STDMETHODIMP DisplayAttributeInfo::GetDescription(BSTR *description) {
    if (!description) return E_INVALIDARG;
    *description = SysAllocString(description_);
    return *description ? S_OK : E_OUTOFMEMORY;
}

STDMETHODIMP DisplayAttributeInfo::GetAttributeInfo(TF_DISPLAYATTRIBUTE *attribute) {
    if (!attribute) return E_INVALIDARG;
    *attribute = attribute_;
    return S_OK;
}

DisplayAttributeEnum::DisplayAttributeEnum() { DllAddRef(); }
DisplayAttributeEnum::~DisplayAttributeEnum() { DllRelease(); }

STDMETHODIMP DisplayAttributeEnum::QueryInterface(REFIID riid, void **object) {
    if (!object) return E_INVALIDARG;
    if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, IID_IEnumTfDisplayAttributeInfo)) {
        *object = static_cast<IEnumTfDisplayAttributeInfo *>(this);
        AddRef();
        return S_OK;
    }
    *object = nullptr;
    return E_NOINTERFACE;
}

STDMETHODIMP_(ULONG) DisplayAttributeEnum::AddRef() { return InterlockedIncrement(&references_); }

STDMETHODIMP_(ULONG) DisplayAttributeEnum::Release() {
    LONG count = InterlockedDecrement(&references_);
    if (!count) delete this;
    return count;
}

STDMETHODIMP DisplayAttributeEnum::Clone(IEnumTfDisplayAttributeInfo **clone) {
    if (!clone) return E_INVALIDARG;
    auto *copy = new (std::nothrow) DisplayAttributeEnum();
    if (!copy) return E_OUTOFMEMORY;
    copy->index_ = index_;
    *clone = copy;
    return S_OK;
}

STDMETHODIMP DisplayAttributeEnum::Next(ULONG count, ITfDisplayAttributeInfo **infos, ULONG *fetched) {
    if (!infos) return E_INVALIDARG;
    ULONG got = 0;
    while (got < count && index_ < DisplayAttributeInfo::kCount) {
        infos[got] = DisplayAttributeInfo::At(index_);
        if (!infos[got]) break;
        got++;
        index_++;
    }
    if (fetched) *fetched = got;
    return got == count ? S_OK : S_FALSE;
}

STDMETHODIMP DisplayAttributeEnum::Reset() {
    index_ = 0;
    return S_OK;
}

STDMETHODIMP DisplayAttributeEnum::Skip(ULONG count) {
    index_ += count;
    return index_ <= DisplayAttributeInfo::kCount ? S_OK : S_FALSE;
}

}  // namespace araso
