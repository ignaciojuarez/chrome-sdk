// Copyright 2026 Cobble Chromium SDK Authors
// SPDX-License-Identifier: GPL-3.0-only

#include "chrome/browser/ui/cobble/cobble_website_data.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <tuple>
#include <variant>
#include <vector>

#include "base/functional/bind.h"
#include "base/compiler_specific.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/time/time.h"
#include "base/values.h"
#include "chrome/browser/browsing_data/chrome_browsing_data_model_delegate.h"
#include "chrome/browser/browsing_data/chrome_browsing_data_remover_constants.h"
#include "chrome/browser/profiles/keep_alive/profile_keep_alive_types.h"
#include "chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h"
#include "chrome/browser/profiles/profile.h"
#include "components/browsing_data/content/browsing_data_model.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/browsing_data_filter_builder.h"
#include "content/public/browser/browsing_data_remover.h"
#include "content/public/browser/storage_partition.h"
#include "net/cookies/canonical_cookie.h"
#include "net/cookies/cookie_constants.h"
#include "net/cookies/cookie_options.h"
#include "net/base/registry_controlled_domains/registry_controlled_domain.h"
#include "mojo/public/cpp/bindings/callback_helpers.h"
#include "storage/browser/quota/special_storage_policy.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"
#include "url/gurl.h"

namespace {

class PendingRequest {
 public:
  virtual ~PendingRequest() = default;
  virtual void CancelForShutdown() = 0;
  virtual bool UsesProfile(Profile* profile) const = 0;
};

using PendingRequests = std::vector<std::unique_ptr<PendingRequest>>;
PendingRequests& Requests();
std::unique_ptr<PendingRequest> TakePendingRequest(PendingRequest* request);

void Reply(CCSWebsiteDataStringCallback callback,
           void* callback_data,
           const std::string& value,
           const std::string& error) {
  if (callback) {
    callback(callback_data, value.empty() ? nullptr : value.c_str(),
             error.empty() ? nullptr : error.c_str());
  }
}

std::optional<std::string> RegistrableDomain(std::string_view host) {
  if (host.empty() || host.size() > 253) {
    return std::nullopt;
  }
  const bool may_be_ipv6 = host.find(':') != std::string_view::npos;
  const GURL url(std::string("https://") +
                 (may_be_ipv6 ? "[" + std::string(host) + "]"
                              : std::string(host)) +
                 "/");
  if (!url.is_valid() || url.HostNoBracketsPiece() != host) {
    return std::nullopt;
  }
  std::string domain =
      net::registry_controlled_domains::GetDomainAndRegistry(
          host, net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES);
  return domain.empty() ? std::optional<std::string>(host) : domain;
}

bool IsCanonicalRegistrableDomain(std::string_view domain) {
  auto canonical = RegistrableDomain(domain);
  return canonical && *canonical == domain;
}

std::optional<std::pair<std::string, GURL>> CanonicalHTTPSHost(
    const char* host_utf8) {
  if (!host_utf8) {
    return std::nullopt;
  }
  const size_t length = UNSAFE_BUFFERS(strnlen(host_utf8, size_t{254}));
  if (!length || length == 254) {
    return std::nullopt;
  }
  std::string host(host_utf8, length);
  const bool ipv6 = host.find(':') != std::string::npos;
  GURL url("https://" + (ipv6 ? "[" + host + "]" : host) + "/");
  if (!url.is_valid() || !url.SchemeIs("https") ||
      url.HostNoBracketsPiece() != host || url.EffectiveIntPort() != 443) {
    return std::nullopt;
  }
  return std::pair(std::move(host), std::move(url));
}

bool IsRepresentableCookie(const net::CanonicalCookie& cookie) {
  return !cookie.IsPartitioned() &&
         cookie.SourceScheme() == net::CookieSourceScheme::kSecure &&
         cookie.SourcePort() == 443;
}

const char* SameSiteString(net::CookieSameSite same_site) {
  switch (same_site) {
    case net::CookieSameSite::UNSPECIFIED:
      return "unspecified";
    case net::CookieSameSite::NO_RESTRICTION:
      return "none";
    case net::CookieSameSite::LAX_MODE:
      return "lax";
    case net::CookieSameSite::STRICT_MODE:
      return "strict";
  }
  return "unspecified";
}

std::optional<net::CookieSameSite> ParseSameSite(std::string_view same_site) {
  if (same_site == "unspecified") return net::CookieSameSite::UNSPECIFIED;
  if (same_site == "none") return net::CookieSameSite::NO_RESTRICTION;
  if (same_site == "lax") return net::CookieSameSite::LAX_MODE;
  if (same_site == "strict") return net::CookieSameSite::STRICT_MODE;
  return std::nullopt;
}

std::optional<std::vector<net::CanonicalCookie>> ParseCookies(
    const char* json_utf8,
    const GURL& source_url) {
  if (!json_utf8) {
    return std::nullopt;
  }
  constexpr size_t kMaximumJSONBytes = 1024 * 1024;
  const size_t length =
      UNSAFE_BUFFERS(strnlen(json_utf8, kMaximumJSONBytes + 1));
  if (length > kMaximumJSONBytes) {
    return std::nullopt;
  }
  auto parsed = base::JSONReader::Read(std::string_view(json_utf8, length),
                                       base::JSON_PARSE_RFC);
  if (!parsed || !parsed->is_list() || parsed->GetList().size() > 4096) {
    return std::nullopt;
  }
  std::vector<net::CanonicalCookie> cookies;
  std::set<std::tuple<std::string, std::string, std::string>> keys;
  cookies.reserve(parsed->GetList().size());
  const base::Time now = base::Time::Now();
  for (const auto& value : parsed->GetList()) {
    if (!value.is_dict() || value.GetDict().size() != 8) {
      return std::nullopt;
    }
    const auto& item = value.GetDict();
    const std::string* name = item.FindString("name");
    const std::string* cookie_value = item.FindString("value");
    const std::string* domain = item.FindString("domain");
    const std::string* path = item.FindString("path");
    const std::string* same_site_text = item.FindString("sameSite");
    std::optional<bool> secure = item.FindBool("secure");
    std::optional<bool> http_only = item.FindBool("httpOnly");
    const base::Value* expiry_value = item.Find("expiry");
    auto same_site = same_site_text ? ParseSameSite(*same_site_text)
                                    : std::nullopt;
    if (!name || !cookie_value || !domain || !path || !secure || !http_only ||
        !expiry_value || !same_site) {
      return std::nullopt;
    }
    base::Time expiry;
    if (!expiry_value->is_none()) {
      if (!expiry_value->is_double() && !expiry_value->is_int()) {
        return std::nullopt;
      }
      const double seconds = expiry_value->is_double()
                                 ? expiry_value->GetDouble()
                                 : static_cast<double>(expiry_value->GetInt());
      if (!std::isfinite(seconds) || seconds < 0 ||
          seconds > base::Time::Max().InSecondsFSinceUnixEpoch()) {
        return std::nullopt;
      }
      expiry = base::Time::FromSecondsSinceUnixEpoch(seconds);
      if (expiry <= now) {
        return std::nullopt;
      }
    }
    const bool domain_cookie = domain->starts_with('.');
    if (!domain_cookie && *domain != source_url.host()) {
      return std::nullopt;
    }
    const std::string domain_attribute = domain_cookie ? *domain : "";
    net::CookieInclusionStatus status;
    auto cookie = net::CanonicalCookie::CreateSanitizedCookie(
        source_url, *name, *cookie_value, domain_attribute, *path, now,
        expiry, base::Time(), *secure, *http_only, *same_site,
        net::COOKIE_PRIORITY_DEFAULT, std::nullopt, &status);
    if (!cookie || cookie->Name() != *name || cookie->Value() != *cookie_value ||
        cookie->Domain() != *domain || cookie->Path() != *path ||
        cookie->ExpiryDate() != expiry || cookie->SecureAttribute() != *secure ||
        cookie->IsHttpOnly() != *http_only || cookie->SameSite() != *same_site ||
        !cookie->IsDomainMatch(source_url.host()) ||
        !IsRepresentableCookie(*cookie)) {
      return std::nullopt;
    }
    if (!keys.emplace(cookie->Name(), cookie->Domain(), cookie->Path()).second) {
      return std::nullopt;
    }
    cookies.push_back(std::move(*cookie));
  }
  return cookies;
}

class PendingRemoval final : public PendingRequest,
                             public content::BrowsingDataRemover::Observer {
 public:
  PendingRemoval(Profile* profile,
                 CCSWebsiteDataStringCallback callback,
                 void* callback_data)
      : profile_keep_alive_(ScopedProfileKeepAlive::TryAcquire(
            profile->GetOriginalProfile(),
            ProfileKeepAliveOrigin::kClearingBrowsingData)),
        profile_(profile),
        remover_(profile->GetBrowsingDataRemover()),
        callback_(callback),
        callback_data_(callback_data) {}

  bool IsReady() const { return profile_keep_alive_ && remover_; }
  bool UsesProfile(Profile* profile) const override {
    return profile_ == profile;
  }

  void Remove(uint64_t remove_mask,
              const std::optional<std::string>& domain,
              base::Time begin) {
    remover_->AddObserver(this);
    if (domain) {
      auto filter = content::BrowsingDataFilterBuilder::Create(
          content::BrowsingDataFilterBuilder::Mode::kDelete);
      filter->AddRegisterableDomain(*domain);
      remover_->RemoveWithFilterAndReply(
          begin, base::Time::Max(), remove_mask,
          content::BrowsingDataRemover::ORIGIN_TYPE_UNPROTECTED_WEB,
          std::move(filter), this);
      return;
    }
    remover_->RemoveAndReply(
        begin, base::Time::Max(), remove_mask,
        content::BrowsingDataRemover::ORIGIN_TYPE_UNPROTECTED_WEB, this);
  }

  void CancelForShutdown() override {
    if (completed_) {
      return;
    }
    completed_ = true;
    remover_->RemoveObserver(this);
    Reply(callback_, TakeCallbackData(), "", "Chromium runtime is stopping.");
  }

  void OnBrowsingDataRemoverDone(uint64_t failed_data_types) override {
    if (completed_) {
      return;
    }
    completed_ = true;
    remover_->RemoveObserver(this);
    // Keep this request alive while the client callback may reenter Chromium.
    auto request_lifetime = TakePendingRequest(this);
    (void)request_lifetime;
    if (failed_data_types) {
      Reply(callback_, TakeCallbackData(), "",
            "Chromium could not remove all requested website data.");
    } else {
      Reply(callback_, TakeCallbackData(), "{}", "");
    }
  }

 private:
  void* TakeCallbackData() {
    void* data = callback_data_.get();
    callback_data_ = nullptr;
    return data;
  }

  std::unique_ptr<ScopedProfileKeepAlive> profile_keep_alive_;
  raw_ptr<Profile> profile_;
  raw_ptr<content::BrowsingDataRemover> remover_;
  CCSWebsiteDataStringCallback callback_ = nullptr;
  raw_ptr<void> callback_data_ = nullptr;
  bool completed_ = false;
};

class PendingSiteList final : public PendingRequest {
 public:
  PendingSiteList(Profile* profile,
                  CCSWebsiteDataStringCallback callback,
                  void* callback_data)
      : profile_keep_alive_(ScopedProfileKeepAlive::TryAcquire(
            profile->GetOriginalProfile(),
            ProfileKeepAliveOrigin::kClearingBrowsingData)),
        profile_(profile),
        callback_(callback),
        callback_data_(callback_data) {}

  bool IsReady() const { return profile_keep_alive_ && profile_; }
  bool UsesProfile(Profile* profile) const override {
    return profile_ == profile;
  }

  void Start() {
    BrowsingDataModel::BuildFromDisk(
        profile_, ChromeBrowsingDataModelDelegate::CreateForProfile(profile_),
        base::BindOnce(&PendingSiteList::ModelReady,
                       weak_factory_.GetWeakPtr()));
  }

  void CancelForShutdown() override {
    if (completed_) {
      return;
    }
    completed_ = true;
    weak_factory_.InvalidateWeakPtrs();
    Reply(callback_, TakeCallbackData(), "", "Chromium runtime is stopping.");
  }

 private:
  void ModelReady(std::unique_ptr<BrowsingDataModel> model) {
    if (completed_) {
      return;
    }
    completed_ = true;
    auto request_lifetime = TakePendingRequest(this);
    (void)request_lifetime;
    if (!model) {
      Reply(callback_, TakeCallbackData(), "",
            "Chromium could not read website data.");
      return;
    }

    std::set<std::string> domains;
    storage::SpecialStoragePolicy* policy = profile_->GetSpecialStoragePolicy();
    for (const auto& entry : *model) {
      if (!std::holds_alternative<std::string>(entry.data_owner.get())) {
        continue;
      }
      const url::Origin origin =
          BrowsingDataModel::GetOriginForDataKey(entry.data_key.get());
      if (!origin.GetURL().SchemeIsHTTPOrHTTPS() ||
          (policy && policy->IsStorageProtected(origin.GetURL()))) {
        continue;
      }
      auto domain = RegistrableDomain(
          BrowsingDataModel::GetHost(entry.data_owner.get()));
      if (domain) {
        domains.insert(std::move(*domain));
      }
    }

    base::ListValue value;
    for (const auto& domain : domains) {
      value.Append(domain);
    }
    auto json = base::WriteJson(value);
    if (!json) {
      Reply(callback_, TakeCallbackData(), "",
            "Chromium could not encode website data.");
      return;
    }
    Reply(callback_, TakeCallbackData(), *json, "");
  }

  void* TakeCallbackData() {
    void* data = callback_data_.get();
    callback_data_ = nullptr;
    return data;
  }

  std::unique_ptr<ScopedProfileKeepAlive> profile_keep_alive_;
  raw_ptr<Profile> profile_;
  CCSWebsiteDataStringCallback callback_ = nullptr;
  raw_ptr<void> callback_data_ = nullptr;
  bool completed_ = false;
  base::WeakPtrFactory<PendingSiteList> weak_factory_{this};
};

class PendingCookies final : public PendingRequest {
 public:
  PendingCookies(Profile* profile,
                 std::string host,
                 GURL source_url,
                 CCSWebsiteDataStringCallback callback,
                 void* callback_data)
      : profile_keep_alive_(ScopedProfileKeepAlive::TryAcquire(
            profile->GetOriginalProfile(),
            ProfileKeepAliveOrigin::kClearingBrowsingData)),
        profile_(profile),
        manager_(profile->GetDefaultStoragePartition()
                     ->GetCookieManagerForBrowserProcess()),
        host_(std::move(host)),
        source_url_(std::move(source_url)),
        callback_(callback),
        callback_data_(callback_data) {}

  bool IsReady() const { return profile_keep_alive_ && manager_; }
  bool UsesProfile(Profile* profile) const override { return profile_ == profile; }

  void Export() {
    manager_->GetAllCookies(mojo::WrapCallbackWithDropHandler(
        base::BindOnce(&PendingCookies::ExportReady,
                       weak_factory_.GetWeakPtr()),
        base::BindOnce(&PendingCookies::CookieStoreUnavailable,
                       weak_factory_.GetWeakPtr())));
  }

  void Replace(std::vector<net::CanonicalCookie> cookies) {
    replacements_ = std::move(cookies);
    manager_->GetAllCookies(mojo::WrapCallbackWithDropHandler(
        base::BindOnce(&PendingCookies::ReplacementReady,
                       weak_factory_.GetWeakPtr()),
        base::BindOnce(&PendingCookies::CookieStoreUnavailable,
                       weak_factory_.GetWeakPtr())));
  }

  void CancelForShutdown() override {
    if (completed_) return;
    completed_ = true;
    weak_factory_.InvalidateWeakPtrs();
    Reply(callback_, TakeCallbackData(), "", "Chromium runtime is stopping.");
  }

 private:
  void CookieStoreUnavailable() {
    FinishError("Chromium cookie storage became unavailable.");
  }

  bool IsLiveMatch(const net::CanonicalCookie& cookie) const {
    return cookie.IsDomainMatch(host_) &&
           (cookie.ExpiryDate().is_null() ||
            cookie.ExpiryDate() > base::Time::Now());
  }

  void ExportReady(const net::CookieList& cookies) {
    if (completed_) return;
    base::ListValue exported;
    size_t skipped = 0;
    for (const auto& cookie : cookies) {
      if (!IsLiveMatch(cookie)) continue;
      if (!IsRepresentableCookie(cookie)) {
        ++skipped;
        continue;
      }
      base::DictValue item;
      item.Set("name", cookie.Name());
      item.Set("value", cookie.Value());
      item.Set("domain", cookie.Domain());
      item.Set("path", cookie.Path());
      if (cookie.ExpiryDate().is_null()) {
        item.Set("expiry", base::Value());
      } else {
        item.Set("expiry", cookie.ExpiryDate().InSecondsFSinceUnixEpoch());
      }
      item.Set("secure", cookie.SecureAttribute());
      item.Set("httpOnly", cookie.IsHttpOnly());
      item.Set("sameSite", SameSiteString(cookie.SameSite()));
      exported.Append(std::move(item));
    }
    base::DictValue snapshot;
    snapshot.Set("cookies", std::move(exported));
    snapshot.Set("skipped", static_cast<int>(skipped));
    auto json = base::WriteJson(snapshot);
    if (!json) {
      FinishError("Chromium could not encode cookies.");
      return;
    }
    Finish(std::move(*json));
  }

  void ReplacementReady(const net::CookieList& cookies) {
    if (completed_) return;
    std::set<std::tuple<std::string, std::string, std::string>> replacement_keys;
    for (const auto& cookie : replacements_) {
      replacement_keys.emplace(cookie.Name(), cookie.Domain(), cookie.Path());
    }
    for (const auto& cookie : cookies) {
      if (!IsLiveMatch(cookie) || cookie.IsPartitioned()) continue;
      if (!IsRepresentableCookie(cookie)) {
        FinishError("Existing cookies contain unsupported metadata.");
        return;
      }
      if (!replacement_keys.contains(std::make_tuple(
              cookie.Name(), cookie.Domain(), cookie.Path()))) {
        removals_.push_back(cookie);
      }
    }
    SetNext();
  }

  void DeleteNext() {
    if (completed_) return;
    if (index_ == removals_.size()) {
      FinishResult();
      return;
    }
    manager_->DeleteCanonicalCookie(
        removals_[index_++],
        mojo::WrapCallbackWithDefaultInvokeIfNotRun(
            base::BindOnce(&PendingCookies::Deleted,
                           weak_factory_.GetWeakPtr()),
            false));
  }

  void Deleted(bool success) {
    success ? ++deleted_ : ++rejected_;
    DeleteNext();
  }

  void SetNext() {
    if (completed_) return;
    if (index_ == replacements_.size()) {
      if (rejected_) {
        FinishResult();
      } else {
        index_ = 0;
        DeleteNext();
      }
      return;
    }
    manager_->SetCanonicalCookie(
        replacements_[index_++], source_url_,
        net::CookieOptions::MakeAllInclusive(),
        mojo::WrapCallbackWithDropHandler(
            base::BindOnce(&PendingCookies::Set,
                           weak_factory_.GetWeakPtr()),
            base::BindOnce(&PendingCookies::CookieStoreUnavailable,
                           weak_factory_.GetWeakPtr())));
  }

  void Set(net::CookieAccessResult result) {
    result.status.IsInclude() ? ++imported_ : ++rejected_;
    SetNext();
  }

  void FinishResult() {
    base::DictValue result;
    result.Set("deleted", static_cast<int>(deleted_));
    result.Set("imported", static_cast<int>(imported_));
    result.Set("rejected", static_cast<int>(rejected_));
    auto json = base::WriteJson(result);
    if (!json) {
      FinishError("Chromium could not encode the cookie result.");
    } else {
      Finish(std::move(*json));
    }
  }

  void FinishError(const char* error) {
    if (completed_) return;
    completed_ = true;
    auto request_lifetime = TakePendingRequest(this);
    (void)request_lifetime;
    Reply(callback_, TakeCallbackData(), "", error);
  }

  void Finish(std::string value) {
    if (completed_) return;
    completed_ = true;
    auto request_lifetime = TakePendingRequest(this);
    (void)request_lifetime;
    Reply(callback_, TakeCallbackData(), value, "");
  }

  void* TakeCallbackData() {
    void* data = callback_data_.get();
    callback_data_ = nullptr;
    return data;
  }

  std::unique_ptr<ScopedProfileKeepAlive> profile_keep_alive_;
  raw_ptr<Profile> profile_;
  raw_ptr<network::mojom::CookieManager> manager_;
  std::string host_;
  GURL source_url_;
  CCSWebsiteDataStringCallback callback_ = nullptr;
  raw_ptr<void> callback_data_ = nullptr;
  net::CookieList removals_;
  net::CookieList replacements_;
  size_t index_ = 0;
  size_t deleted_ = 0;
  size_t imported_ = 0;
  size_t rejected_ = 0;
  bool completed_ = false;
  base::WeakPtrFactory<PendingCookies> weak_factory_{this};
};

PendingRequests& Requests() {
  static base::NoDestructor<PendingRequests> requests;
  return *requests;
}

std::unique_ptr<PendingRequest> TakePendingRequest(PendingRequest* request) {
  auto& requests = Requests();
  auto found = std::ranges::find_if(requests, [request](const auto& pending) {
    return pending.get() == request;
  });
  if (found == requests.end()) {
    return nullptr;
  }
  auto result = std::move(*found);
  requests.erase(found);
  return result;
}

void CancelPendingRequestsForShutdown() {
  PendingRequests requests = std::move(Requests());
  for (const auto& request : requests) {
    request->CancelForShutdown();
  }
}

void EnsureShutdownCallback() {
  static bool registered = false;
  if (!registered) {
    cobble_chromium::RegisterShutdownCallback(&CancelPendingRequestsForShutdown);
    registered = true;
  }
}

void ReplyError(CCSWebsiteDataStringCallback callback,
                void* callback_data,
                const char* error) {
  Reply(callback, callback_data, "", error);
}

Profile* ValidateContext(CCSContextRef context,
                         void* callback_data,
                         CCSWebsiteDataStringCallback callback) {
  EnsureShutdownCallback();
  if (cobble_chromium::IsStopping()) {
    ReplyError(callback, callback_data, "Chromium runtime is stopping.");
    return nullptr;
  }
  Profile* profile = cobble_chromium::ContextProfile(context);
  if (!profile) {
    ReplyError(callback, callback_data, "Invalid Chromium context.");
    return nullptr;
  }
  if (profile->IsOffTheRecord()) {
    ReplyError(callback, callback_data,
               "Website data controls are unavailable in private contexts.");
    return nullptr;
  }
  return profile;
}

void StartRemoval(Profile* profile,
                  uint32_t category_mask,
                  const std::optional<std::string>& domain,
                  base::Time begin,
                  void* callback_data,
                  CCSWebsiteDataStringCallback callback) {
  uint64_t remove_mask = 0;
  if (category_mask & CCS_WEBSITE_DATA_SITE_DATA) {
    remove_mask |= chrome_browsing_data_remover::DATA_TYPE_SITE_DATA;
  }
  if (category_mask & CCS_WEBSITE_DATA_CACHE) {
    remove_mask |= content::BrowsingDataRemover::DATA_TYPE_CACHE;
  }
  auto request =
      std::make_unique<PendingRemoval>(profile, callback, callback_data);
  if (!request->IsReady()) {
    request.reset();
    ReplyError(callback, callback_data, "The Chromium profile is closing.");
    return;
  }
  PendingRemoval* request_pointer = request.get();
  Requests().push_back(std::move(request));
  request_pointer->Remove(remove_mask, domain, begin);
}

}  // namespace

namespace cobble_chromium {

bool HasPendingWebsiteDataWork(Profile* profile) {
  return std::ranges::any_of(Requests(), [profile](const auto& request) {
    return request->UsesProfile(profile);
  });
}

}  // namespace cobble_chromium

extern "C" void CCSWebsiteDataRemove(
    CCSContextRef context,
    const CCSWebsiteDataRemovalV1* removal,
    void* callback_data,
    CCSWebsiteDataStringCallback callback) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!callback) {
    return;
  }
  Profile* profile = ValidateContext(context, callback_data, callback);
  if (!profile) {
    return;
  }
  constexpr uint32_t kKnownCategories =
      CCS_WEBSITE_DATA_SITE_DATA | CCS_WEBSITE_DATA_CACHE;
  if (!removal || removal->struct_size < sizeof(CCSWebsiteDataRemovalV1) ||
      !removal->category_mask ||
      (removal->category_mask & ~kKnownCategories) || removal->all_time > 1) {
    ReplyError(callback, callback_data,
               "Choose valid website-data removal options.");
    return;
  }
  std::optional<std::string> domain;
  if (removal->registrable_domain_utf8) {
    // SAFETY: The C ABI requires a NUL-terminated string. Bound the scan before
    // allocating so malformed input cannot cause an unbounded read or copy.
    const size_t length = UNSAFE_BUFFERS(
        strnlen(removal->registrable_domain_utf8, size_t{254}));
    if (length == 254) {
      ReplyError(callback, callback_data,
                 "Choose a canonical website-data domain.");
      return;
    }
    domain.emplace(removal->registrable_domain_utf8, length);
    if (!IsCanonicalRegistrableDomain(*domain)) {
      ReplyError(callback, callback_data,
                 "Choose a canonical website-data domain.");
      return;
    }
  }
  base::Time begin = base::Time::Min();
  if (removal->all_time) {
    if (removal->modified_since_unix_seconds != 0) {
      ReplyError(callback, callback_data,
                 "All-time website-data removal cannot include a cutoff.");
      return;
    }
  } else {
    const double cutoff = removal->modified_since_unix_seconds;
    if ((removal->category_mask & CCS_WEBSITE_DATA_SITE_DATA) ||
        !std::isfinite(cutoff) || cutoff < 0 ||
        cutoff > base::Time::Now().InSecondsFSinceUnixEpoch()) {
      ReplyError(callback, callback_data,
                 "Time-bounded removal is available only for cached resources.");
      return;
    }
    begin = base::Time::FromSecondsSinceUnixEpoch(cutoff);
  }
  StartRemoval(profile, removal->category_mask, domain, begin, callback_data,
               callback);
}

extern "C" void CCSWebsiteDataClearCache(
    CCSContextRef context,
    void* callback_data,
    CCSWebsiteDataStringCallback callback) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!callback) {
    return;
  }
  Profile* profile = ValidateContext(context, callback_data, callback);
  if (!profile) {
    return;
  }
  StartRemoval(profile, CCS_WEBSITE_DATA_CACHE, std::nullopt,
               base::Time::Min(), callback_data, callback);
}

extern "C" void CCSWebsiteDataListSites(
    CCSContextRef context,
    void* callback_data,
    CCSWebsiteDataStringCallback callback) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!callback) {
    return;
  }
  Profile* profile = ValidateContext(context, callback_data, callback);
  if (!profile) {
    return;
  }
  auto request =
      std::make_unique<PendingSiteList>(profile, callback, callback_data);
  if (!request->IsReady()) {
    request.reset();
    ReplyError(callback, callback_data, "The Chromium profile is closing.");
    return;
  }
  PendingSiteList* request_pointer = request.get();
  Requests().push_back(std::move(request));
  request_pointer->Start();
}

extern "C" void CCSWebsiteDataRemoveSite(
    CCSContextRef context,
    const char* registrable_domain_utf8,
    void* callback_data,
    CCSWebsiteDataStringCallback callback) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!callback) {
    return;
  }
  const CCSWebsiteDataRemovalV1 removal = {
      .struct_size = sizeof(CCSWebsiteDataRemovalV1),
      .category_mask = CCS_WEBSITE_DATA_SITE_DATA | CCS_WEBSITE_DATA_CACHE,
      .registrable_domain_utf8 =
          registrable_domain_utf8 ? registrable_domain_utf8 : "",
      .modified_since_unix_seconds = 0,
      .all_time = 1,
  };
  CCSWebsiteDataRemove(context, &removal, callback_data, callback);
}

extern "C" void CCSCookiesExport(
    CCSContextRef context,
    const char* https_host_utf8,
    void* callback_data,
    CCSWebsiteDataStringCallback callback) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!callback) return;
  Profile* profile = ValidateContext(context, callback_data, callback);
  if (!profile) return;
  auto host = CanonicalHTTPSHost(https_host_utf8);
  if (!host) {
    ReplyError(callback, callback_data, "Choose a canonical HTTPS host.");
    return;
  }
  auto request = std::make_unique<PendingCookies>(
      profile, std::move(host->first), std::move(host->second), callback,
      callback_data);
  if (!request->IsReady()) {
    ReplyError(callback, callback_data, "The Chromium profile is closing.");
    return;
  }
  PendingCookies* request_pointer = request.get();
  Requests().push_back(std::move(request));
  request_pointer->Export();
}

extern "C" void CCSCookiesReplace(
    CCSContextRef context,
    const char* https_host_utf8,
    const char* cookies_json_utf8,
    void* callback_data,
    CCSWebsiteDataStringCallback callback) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!callback) return;
  Profile* profile = ValidateContext(context, callback_data, callback);
  if (!profile) return;
  auto host = CanonicalHTTPSHost(https_host_utf8);
  if (!host) {
    ReplyError(callback, callback_data, "Choose a canonical HTTPS host.");
    return;
  }
  auto cookies = ParseCookies(cookies_json_utf8, host->second);
  if (!cookies) {
    ReplyError(callback, callback_data, "Choose valid HTTPS cookies.");
    return;
  }
  auto request = std::make_unique<PendingCookies>(
      profile, std::move(host->first), std::move(host->second), callback,
      callback_data);
  if (!request->IsReady()) {
    ReplyError(callback, callback_data, "The Chromium profile is closing.");
    return;
  }
  PendingCookies* request_pointer = request.get();
  Requests().push_back(std::move(request));
  request_pointer->Replace(std::move(*cookies));
}
