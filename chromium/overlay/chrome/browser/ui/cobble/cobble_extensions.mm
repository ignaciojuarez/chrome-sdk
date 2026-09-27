// Copyright 2026 Cobble Chromium SDK Authors
// SPDX-License-Identifier: GPL-3.0-only

#include "chrome/browser/ui/cobble/cobble_extensions.h"

#include <algorithm>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/feature_list.h"
#include "base/files/file_path.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/json/json_writer.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/memory/scoped_refptr.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/values.h"
#include "chrome/browser/extensions/extension_action_runner.h"
#include "chrome/browser/extensions/extension_util.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/supervised_user/supervised_user_browser_utils.h"
#include "chrome/common/pref_names.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/web_contents.h"
#include "extensions/browser/disable_reason.h"
#include "extensions/browser/api/declarative_net_request/rules_monitor_service.h"
#include "extensions/browser/api/declarative_net_request/utils.h"
#include "extensions/browser/extension_action.h"
#include "extensions/browser/extension_action_manager.h"
#include "extensions/browser/extension_registrar.h"
#include "extensions/browser/extension_registrar_factory.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extension_registry_observer.h"
#include "extensions/browser/extension_prefs.h"
#include "extensions/browser/extension_system.h"
#include "extensions/browser/management_policy.h"
#include "extensions/browser/permissions/scripting_permissions_modifier.h"
#include "extensions/browser/permissions_manager.h"
#include "extensions/browser/uninstall_reason.h"
#include "extensions/browser/unpacked_installer.h"
#include "extensions/common/extension.h"
#include "extensions/common/manifest.h"
#include "extensions/common/extension_features.h"
#include "extensions/common/permissions/permissions_data.h"
#include "extensions/common/permissions/permission_set.h"
#include "extensions/common/url_pattern.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace {

using extensions::Extension;
using extensions::ExtensionRegistry;

class RegistryObservation final : public extensions::ExtensionRegistryObserver {
 public:
  RegistryObservation(CCSContextRef context, Profile* profile, void* data,
                      CCSExtensionChangedCallback callback)
      : context_(context), data_(data), callback_(callback),
        registry_(ExtensionRegistry::Get(profile)) {
    registry_->AddObserver(this);
  }
  ~RegistryObservation() override {
    if (registry_) registry_->RemoveObserver(this);
  }

  CCSContextRef context() const { return context_; }

  void OnExtensionLoaded(content::BrowserContext*, const Extension*) override {
    Schedule();
  }
  void OnExtensionUnloaded(content::BrowserContext*, const Extension*,
                           extensions::UnloadedExtensionReason) override {
    Schedule();
  }
  void OnExtensionInstalled(content::BrowserContext*, const Extension*,
                             bool) override {
    Schedule();
  }
  void OnExtensionUninstalled(content::BrowserContext*, const Extension*,
                               extensions::UninstallReason) override {
    Schedule();
  }
  void OnShutdown(ExtensionRegistry* registry) override {
    registry->RemoveObserver(this);
    registry_ = nullptr;
    weak_factory_.InvalidateWeakPtrs();
  }

 private:
  void Schedule() {
    if (pending_) return;
    pending_ = true;
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&RegistryObservation::Deliver,
                                  weak_factory_.GetWeakPtr()));
  }
  void Deliver() {
    pending_ = false;
    if (registry_) callback_(data_);
  }

  CCSContextRef context_;
  void* data_;
  CCSExtensionChangedCallback callback_;
  raw_ptr<ExtensionRegistry> registry_;
  bool pending_ = false;
  base::WeakPtrFactory<RegistryObservation> weak_factory_{this};
};

std::vector<std::unique_ptr<RegistryObservation>>& RegistryObservations() {
  static base::NoDestructor<std::vector<std::unique_ptr<RegistryObservation>>>
      observations;
  return *observations;
}

void ReplyError(CCSExtensionStringCallback callback,
                void* callback_data,
                std::string error);
void Reply(CCSExtensionStringCallback callback,
           void* callback_data,
           const std::string& value,
           const std::string& error);

struct PendingInstallState {
  raw_ptr<void> callback_data = nullptr;
  CCSExtensionStringCallback callback = nullptr;
  bool completed = false;

  void* TakeCallbackData() {
    // The client may free its request while handling the completion callback.
    // Release our tracked borrow before transferring control back to it.
    void* data = callback_data.get();
    callback_data = nullptr;
    return data;
  }
};

struct PendingInstall {
  scoped_refptr<extensions::UnpackedInstaller> installer;
  std::shared_ptr<PendingInstallState> state;
  raw_ptr<Profile> profile = nullptr;
};

using PendingInstallers = std::vector<PendingInstall>;

struct PendingRulesReady {
  std::shared_ptr<PendingInstallState> state;
  raw_ptr<Profile> profile = nullptr;
  scoped_refptr<const Extension> extension;
  std::string success_value;
};

PendingInstallers& PendingUnpackedInstallers() {
  static base::NoDestructor<PendingInstallers> installers;
  return *installers;
}

std::vector<PendingRulesReady>& PendingRulesReadiness() {
  static base::NoDestructor<std::vector<PendingRulesReady>> pending;
  return *pending;
}

std::vector<raw_ptr<Profile>>& PendingPermissionChanges() {
  static base::NoDestructor<std::vector<raw_ptr<Profile>>> changes;
  return *changes;
}

void RemovePendingInstall(const PendingInstallState* state) {
  std::erase_if(PendingUnpackedInstallers(),
                [state](const PendingInstall& pending) {
                  return pending.state.get() == state;
                });
}

void Complete(std::shared_ptr<PendingInstallState> state,
              std::string value,
              std::string error) {
  if (state->completed) return;
  state->completed = true;
  RemovePendingInstall(state.get());
  std::erase_if(PendingRulesReadiness(), [&](const PendingRulesReady& pending) {
    return pending.state.get() == state.get();
  });
  Reply(state->callback, state->TakeCallbackData(), value, error);
}

void RunRulesCompletion(std::shared_ptr<PendingInstallState> state,
                        std::optional<std::string> error) {
  if (state->completed) return;
  auto found = std::ranges::find(PendingRulesReadiness(), state,
                                 &PendingRulesReady::state);
  if (found == PendingRulesReadiness().end()) return;
  std::string success_value = found->success_value;
  if (!error && cobble_chromium::IsStopping()) {
    error = "Chromium runtime is stopping.";
  }
  if (!error) {
    const Extension* enabled = ExtensionRegistry::Get(found->profile)
                                   ->enabled_extensions().GetByID(
                                       found->extension->id());
    if (enabled != found->extension.get()) {
      error = "The extension changed before its rules became ready.";
    }
  }
  Complete(std::move(state), error ? "" : std::move(success_value),
           error.value_or(""));
}

void PostRulesCompletion(std::shared_ptr<PendingInstallState> state,
                         std::optional<std::string> error) {
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&RunRulesCompletion, std::move(state),
                                std::move(error)));
}

void ReplyWhenRulesReady(Profile* profile,
                         const Extension& extension,
                         std::shared_ptr<PendingInstallState> state,
                         std::string success_value) {
  if (!extensions::declarative_net_request::HasAnyDNRPermission(extension)) {
    Complete(std::move(state), std::move(success_value), "");
    return;
  }
  auto* service = extensions::declarative_net_request::RulesMonitorService::Get(profile);
  PendingRulesReadiness().push_back(
      {state, profile, base::WrapRefCounted(&extension),
       std::move(success_value)});
  if (!service) {
    PostRulesCompletion(std::move(state), "Declarative rules are unavailable.");
    return;
  }
  base::ScopedClosureRunner dropped(base::BindOnce(
      &PostRulesCompletion, state,
      std::optional<std::string>(
          "The extension was unloaded before its rules became ready.")));
  service->WaitForInitialRulesets(
      extension,
      base::BindOnce(
          [](std::shared_ptr<PendingInstallState> state,
             base::ScopedClosureRunner dropped,
             std::optional<std::string> error) {
            base::OnceClosure unused = dropped.Release();
            PostRulesCompletion(std::move(state), std::move(error));
          },
          std::move(state), std::move(dropped)));
}

void CancelPendingInstallsForShutdown() {
  auto& pending = PendingUnpackedInstallers();
  for (const PendingInstall& install : pending) {
    if (install.state->completed) {
      continue;
    }
    install.state->completed = true;
    ReplyError(install.state->callback, install.state->TakeCallbackData(),
               "Chromium runtime is stopping.");
  }
  pending.clear();
  while (!PendingRulesReadiness().empty()) {
    Complete(PendingRulesReadiness().front().state, "",
             "Chromium runtime is stopping.");
  }
}

void EnsureShutdownCallback() {
  static bool registered = false;
  if (!registered) {
    cobble_chromium::RegisterShutdownCallback(&CancelPendingInstallsForShutdown);
    registered = true;
  }
}

void Reply(CCSExtensionStringCallback callback,
           void* callback_data,
           const std::string& value,
           const std::string& error) {
  if (callback) {
    callback(callback_data, value.empty() ? nullptr : value.c_str(),
             error.empty() ? nullptr : error.c_str());
  }
}

void ReplyValue(CCSExtensionStringCallback callback,
                void* callback_data,
                std::string value) {
  Reply(callback, callback_data, value, "");
}

void ReplyError(CCSExtensionStringCallback callback,
                void* callback_data,
                std::string error) {
  Reply(callback, callback_data, "", error);
}

Profile* NormalProfile(CCSContextRef context,
                       void* callback_data,
                       CCSExtensionStringCallback callback) {
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
               "Extensions are unavailable in private contexts.");
    return nullptr;
  }
  return profile;
}

const Extension* InstalledExtension(Profile* profile, const char* id) {
  return id && *id ? ExtensionRegistry::Get(profile)->GetInstalledExtension(id)
                   : nullptr;
}

void WithholdHostPermissions(Profile* profile, const Extension* extension) {
  auto* permissions = extensions::PermissionsManager::Get(profile);
  if (!permissions || !permissions->CanAffectExtension(*extension)) {
    return;
  }
  scoped_refptr<const Extension> retained(extension);
  extensions::ScriptingPermissionsModifier(profile, retained)
      .SetWithholdHostPermissions(true);
}

base::ListValue Strings(std::vector<std::string> strings) {
  std::sort(strings.begin(), strings.end());
  strings.erase(std::unique(strings.begin(), strings.end()), strings.end());
  base::ListValue result;
  for (std::string& string : strings) {
    result.Append(std::move(string));
  }
  return result;
}

void AppendHosts(const extensions::PermissionSet& permissions,
                 std::vector<std::string>* hosts) {
  const std::vector<std::string> explicit_hosts =
      permissions.explicit_hosts().ToStringVector();
  hosts->insert(hosts->end(), explicit_hosts.begin(), explicit_hosts.end());
  const std::vector<std::string> scriptable_hosts =
      permissions.scriptable_hosts().ToStringVector();
  hosts->insert(hosts->end(), scriptable_hosts.begin(), scriptable_hosts.end());
}

std::string ListJSON(Profile* profile) {
  ExtensionRegistry* registry = ExtensionRegistry::Get(profile);
  auto* permissions = extensions::PermissionsManager::Get(profile);
  base::ListValue list;
  for (const auto& extension :
       registry->GenerateInstalledExtensionsSet(ExtensionRegistry::EVERYTHING)) {
    if (!extension->is_extension()) continue;
    const auto location = extension->location();
    if (extensions::Manifest::IsComponentLocation(location)) continue;
    const char* source = "other";
    if (extensions::Manifest::IsPolicyLocation(location)) {
      source = "policy";
    } else if (location == extensions::mojom::ManifestLocation::kUnpacked) {
      source = "unpacked";
    } else if (location == extensions::mojom::ManifestLocation::kInternal &&
               extension->from_webstore() && !extension->was_installed_by_default()) {
      source = "store";
    }
    auto* system = extensions::ExtensionSystem::Get(profile);
    auto* policy = system ? system->management_policy() : nullptr;
    const bool user_manageable =
        (location == extensions::mojom::ManifestLocation::kUnpacked ||
         (location == extensions::mojom::ManifestLocation::kInternal &&
          extension->from_webstore() &&
          !extension->was_installed_by_default())) &&
        policy && policy->UserMayModifySettings(extension.get(), nullptr) &&
        !policy->MustRemainInstalled(extension.get(), nullptr);
    base::DictValue item;
    item.Set("id", extension->id());
    // M152 Extension::name() is already UTF-8.
    item.Set("name", extension->name());
    item.Set("version", extension->version().GetString());
    item.Set("path", extension->path().AsUTF8Unsafe());
    item.Set("enabled", registry->enabled_extensions().Contains(extension->id()));
    item.Set("source", source);
    item.Set("userManageable", user_manageable);
    uint32_t disable_reasons = 0;
    if (auto* prefs = extensions::ExtensionPrefs::Get(profile)) {
      for (auto reason : prefs->GetDisableReasons(extension->id()))
        disable_reasons |= static_cast<uint32_t>(reason);
    }
    item.Set("disableReasons", static_cast<int>(disable_reasons));
    item.Set("hasAction", extensions::ExtensionActionManager::Get(profile)
                              ->GetExtensionAction(*extension) != nullptr);
    std::vector<std::string> requested_origins;
    AppendHosts(extension->permissions_data()->active_permissions(),
                &requested_origins);
    AppendHosts(extension->permissions_data()->withheld_permissions(),
                &requested_origins);
    item.Set("requestedOrigins", Strings(std::move(requested_origins)));
    std::vector<std::string> allowed_origins;
    if (permissions && permissions->CanAffectExtension(*extension)) {
      if (auto granted = permissions->GetExtensionGrantedPermissions(*extension)) {
        AppendHosts(*granted, &allowed_origins);
      }
    }
    item.Set("allowedOrigins", Strings(std::move(allowed_origins)));
    std::vector<std::string> denied_permissions;
    if (extension->permissions_data()->active_permissions().HasAPIPermission(
            extensions::mojom::APIPermissionID::kHistory)) {
      denied_permissions.push_back("History");
    }
    if (extension->permissions_data()->active_permissions().HasAPIPermission(
            extensions::mojom::APIPermissionID::kNativeMessaging)) {
      denied_permissions.push_back("Native messaging");
    }
    item.Set("deniedPermissions", Strings(std::move(denied_permissions)));
    list.Append(std::move(item));
  }
  std::string json;
  base::JSONWriter::Write(base::Value(std::move(list)), &json);
  return json;
}

}  // namespace

namespace cobble_chromium {

void ClearExtensionObservation(CCSContextRef context) {
  std::erase_if(RegistryObservations(), [context](const auto& observation) {
    return observation->context() == context;
  });
}

}  // namespace cobble_chromium

extern "C" void CCSExtensionObserve(CCSContextRef context,
                                      void* callback_data,
                                      CCSExtensionChangedCallback callback) {
  cobble_chromium::ClearExtensionObservation(context);
  if (!callback || cobble_chromium::IsStopping()) return;
  Profile* profile = cobble_chromium::ContextProfile(context);
  if (!profile || profile->IsOffTheRecord() ||
      !ExtensionRegistry::Get(profile)) return;
  RegistryObservations().push_back(std::make_unique<RegistryObservation>(
      context, profile, callback_data, callback));
}

extern "C" void CCSExtensionList(CCSContextRef context,
                                  void* callback_data,
                                  CCSExtensionStringCallback callback) {
  Profile* profile = NormalProfile(context, callback_data, callback);
  if (profile) {
    ReplyValue(callback, callback_data, ListJSON(profile));
  }
}

extern "C" void CCSExtensionInstallUnpacked(
    CCSContextRef context,
    const char* source_dir_utf8,
    void* callback_data,
    CCSExtensionStringCallback callback) {
  Profile* profile = NormalProfile(context, callback_data, callback);
  if (!profile) {
    return;
  }
  if (!source_dir_utf8 || !*source_dir_utf8) {
    ReplyError(callback, callback_data, "An extension source directory is required.");
    return;
  }
  const base::FilePath source = base::FilePath::FromUTF8Unsafe(source_dir_utf8);
  if (!source.IsAbsolute()) {
    ReplyError(callback, callback_data,
               "The extension source directory must be an absolute path.");
    return;
  }
  // UnpackedInstaller validates the directory on its file task runner.
  // Filesystem checks here would block Chromium's UI thread.
  // M152 only sets WITHHOLD_PERMISSIONS before activation when this feature is
  // enabled. Do not load once with broad host access and revoke it afterward.
  if (!base::FeatureList::IsEnabled(
          extensions_features::kAllowWithholdingExtensionPermissionsOnInstall)) {
    ReplyError(callback, callback_data,
               "Extension installation requires "
               "AllowWithholdingExtensionPermissionsOnInstall.");
    return;
  }
  // An explicit unpacked install is a developer-mode action for this SDK
  // profile. Keep Chromium's policy and host-permission withholding intact.
  PrefService* profile_prefs = profile->GetPrefs();
  if (!profile_prefs->GetBoolean(prefs::kExtensionsUIDeveloperMode)) {
    if (profile_prefs->IsManagedPreference(prefs::kExtensionsUIDeveloperMode) ||
        supervised_user::AreExtensionsPermissionsEnabled(profile)) {
      ReplyError(callback, callback_data,
                 "Developer extensions are disabled by profile policy.");
      return;
    }
    extensions::util::SetDeveloperModeForProfile(profile, true);
  }
  scoped_refptr<extensions::UnpackedInstaller> installer =
      extensions::UnpackedInstaller::Create(profile);
  if (!installer) {
    ReplyError(callback, callback_data, "Could not create the extension installer.");
    return;
  }
  installer->set_be_noisy_on_failure(false);  // Cobble presents callback errors.
  installer->set_allow_incognito_access(false);
  auto state = std::make_shared<PendingInstallState>();
  state->callback_data = callback_data;
  state->callback = callback;
  installer->set_completion_callback(base::BindOnce(
      [](Profile* profile, std::shared_ptr<PendingInstallState> state,
         const Extension* extension, const base::FilePath&,
         const std::u16string& error) {
        if (state->completed) {
          return;
        }
        if (!extension) {
          Complete(state, "", error.empty()
                                   ? "Chromium could not install the extension."
                                   : base::UTF16ToUTF8(error));
          return;
        }
        WithholdHostPermissions(profile, extension);
        base::DictValue result;
        result.Set("id", extension->id());
        std::string json;
        base::JSONWriter::Write(base::Value(std::move(result)), &json);
        RemovePendingInstall(state.get());
        ReplyWhenRulesReady(profile, *extension, std::move(state), std::move(json));
      }, profile, state));
  PendingUnpackedInstallers().push_back({installer, std::move(state), profile});
  installer->Load(source);
}

namespace cobble_chromium {

bool HasPendingExtensionWork(Profile* profile) {
  return std::ranges::any_of(
             PendingUnpackedInstallers(),
             [profile](const PendingInstall& pending) {
               return pending.profile == profile && !pending.state->completed;
             }) ||
         std::ranges::any_of(PendingRulesReadiness(),
             [profile](const PendingRulesReady& pending) {
               return pending.profile == profile && !pending.state->completed;
             }) ||
         std::ranges::find(PendingPermissionChanges(), profile) !=
             PendingPermissionChanges().end();
}

}  // namespace cobble_chromium

extern "C" void CCSExtensionSetEnabled(CCSContextRef context,
                                        const char* extension_id_utf8,
                                        uint8_t enabled,
                                        void* callback_data,
                                        CCSExtensionStringCallback callback) {
  Profile* profile = NormalProfile(context, callback_data, callback);
  if (!profile) {
    return;
  }
  if (!InstalledExtension(profile, extension_id_utf8)) {
    ReplyError(callback, callback_data, "The extension is not installed.");
    return;
  }
  auto* registrar = extensions::ExtensionRegistrarFactory::GetForBrowserContext(profile);
  if (!registrar) {
    ReplyError(callback, callback_data, "The extension registrar is unavailable.");
    return;
  }
  if (enabled) {
    registrar->EnableExtension(extension_id_utf8);
  } else {
    registrar->DisableExtension(
        extension_id_utf8, {extensions::disable_reason::DISABLE_USER_ACTION});
  }
  if (enabled) {
    const Extension* enabled_extension =
        ExtensionRegistry::Get(profile)->enabled_extensions().GetByID(
            extension_id_utf8);
    if (!enabled_extension) {
      ReplyError(callback, callback_data, "Chromium could not enable the extension.");
      return;
    }
    auto state = std::make_shared<PendingInstallState>();
    state->callback_data = callback_data;
    state->callback = callback;
    ReplyWhenRulesReady(profile, *enabled_extension, std::move(state), "{}");
    return;
  }
  ReplyValue(callback, callback_data, "{}");
}

extern "C" void CCSExtensionRemove(CCSContextRef context,
                                    const char* extension_id_utf8,
                                    void* callback_data,
                                    CCSExtensionStringCallback callback) {
  Profile* profile = NormalProfile(context, callback_data, callback);
  if (!profile) {
    return;
  }
  if (!InstalledExtension(profile, extension_id_utf8)) {
    ReplyError(callback, callback_data, "The extension is not installed.");
    return;
  }
  auto* registrar = extensions::ExtensionRegistrarFactory::GetForBrowserContext(profile);
  if (!registrar) {
    ReplyError(callback, callback_data, "The extension registrar is unavailable.");
    return;
  }
  std::u16string error;
  if (!registrar->UninstallExtension(extension_id_utf8,
                                     extensions::UNINSTALL_REASON_USER_INITIATED,
                                     &error)) {
    ReplyError(callback, callback_data,
               error.empty() ? "Chromium could not remove the extension."
                             : base::UTF16ToUTF8(error));
    return;
  }
  ReplyValue(callback, callback_data, "{}");
}

extern "C" void CCSExtensionSetSiteAccess(
    CCSContextRef context,
    const char* extension_id_utf8,
    const char* origin_utf8,
    uint8_t allowed,
    void* callback_data,
    CCSExtensionStringCallback callback) {
  Profile* profile = NormalProfile(context, callback_data, callback);
  if (!profile) {
    return;
  }
  const Extension* extension = InstalledExtension(profile, extension_id_utf8);
  if (!extension) {
    ReplyError(callback, callback_data, "The extension is not installed.");
    return;
  }
  const GURL origin(origin_utf8 ? origin_utf8 : "");
  if (!origin.is_valid() || !origin.SchemeIsHTTPOrHTTPS()) {
    ReplyError(callback, callback_data, "Site access requires an http(s) URL.");
    return;
  }
  auto* permissions = extensions::PermissionsManager::Get(profile);
  if (!permissions || !permissions->CanAffectExtension(*extension)) {
    ReplyError(callback, callback_data,
               "This extension's site access cannot be changed.");
    return;
  }
  // GrantHostPermission creates a runtime host pattern. Authorize the exact
  // origin through Chromium's manifest-aware user-site-access policy first.
  if (allowed && !permissions->CanUserSelectSiteAccess(
                     *extension, origin,
                     extensions::PermissionsManager::UserSiteAccess::kOnSite)) {
    ReplyError(callback, callback_data,
               "This extension did not request access to that site.");
    return;
  }
  URLPattern site(URLPattern::SCHEME_HTTP | URLPattern::SCHEME_HTTPS);
  if (site.Parse(url::Origin::Create(origin).Serialize() + "/*") !=
      URLPattern::ParseResult::kSuccess) {
    ReplyError(callback, callback_data, "Could not parse the site origin.");
    return;
  }
  scoped_refptr<const Extension> retained(extension);
  extensions::ScriptingPermissionsModifier modifier(profile, retained);
  // Reply only after Chromium propagates the changed permissions. The caller
  // may immediately reload and expect its grant or revocation to take effect.
  PendingPermissionChanges().push_back(profile);
  auto done = base::BindOnce(
      [](Profile* profile, CCSExtensionStringCallback callback,
         void* callback_data) {
        auto& changes = PendingPermissionChanges();
        auto found = std::ranges::find(changes, profile);
        if (found != changes.end()) {
          changes.erase(found);
        }
        ReplyValue(callback, callback_data, "{}");
      },
      profile, callback, callback_data);
  if (allowed) {
    modifier.GrantHostPermission(site, std::move(done));
  } else if (permissions->HasGrantedHostPermission(*extension, origin)) {
    modifier.RemoveHostPermissions(site, std::move(done));
  } else {
    std::move(done).Run();
  }
}

extern "C" void CCSExtensionPerformAction(
    CCSContextRef context,
    CCSPageRef page,
    const char* extension_id_utf8,
    void* callback_data,
    CCSExtensionStringCallback callback) {
  Profile* profile = NormalProfile(context, callback_data, callback);
  if (!profile) {
    return;
  }
  content::WebContents* contents = cobble_chromium::PageWebContents(page);
  if (!contents || contents->GetBrowserContext() != profile) {
    ReplyError(callback, callback_data,
               "The extension action page does not belong to this context.");
    return;
  }
  const Extension* extension = InstalledExtension(profile, extension_id_utf8);
  if (!extension) {
    ReplyError(callback, callback_data, "The extension is not installed.");
    return;
  }
  if (!extensions::ExtensionActionManager::Get(profile)
           ->GetExtensionAction(*extension)) {
    ReplyError(callback, callback_data, "The extension has no action.");
    return;
  }
  auto* runner = extensions::ExtensionActionRunner::GetForWebContents(contents);
  if (!runner) {
    ReplyError(callback, callback_data, "The extension action runner is unavailable.");
    return;
  }
  // An action must not implicitly grant activeTab or a host permission.
  switch (runner->RunAction(extension, /*grant_tab_permissions=*/false)) {
    case extensions::ExtensionAction::ShowAction::kNone:
      ReplyValue(callback, callback_data, "{}");
      return;
    case extensions::ExtensionAction::ShowAction::kShowPopup:
      ReplyError(callback, callback_data,
                 "Extension popups are not supported by this embedding yet.");
      return;
    case extensions::ExtensionAction::ShowAction::kToggleSidePanel:
      ReplyError(callback, callback_data,
                 "Extension side panels are not supported by this embedding yet.");
      return;
  }
}
