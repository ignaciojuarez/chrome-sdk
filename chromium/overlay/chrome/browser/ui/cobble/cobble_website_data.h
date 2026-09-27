// Copyright 2026 Cobble Chromium SDK Authors
// SPDX-License-Identifier: GPL-3.0-only

#ifndef CHROME_BROWSER_UI_COBBLE_COBBLE_WEBSITE_DATA_H_
#define CHROME_BROWSER_UI_COBBLE_COBBLE_WEBSITE_DATA_H_

#include "cobble_chromium.h"

#if defined(__cplusplus)
class Profile;
#endif

#if defined(__cplusplus)
extern "C" {
#endif

// Exactly one callback string is non-null. String storage is valid only for
// the callback. Website-data operations complete asynchronously; retain
// callback_data.
typedef void (*CCSWebsiteDataStringCallback)(void* callback_data,
                                             const char* value_utf8,
                                             const char* error_utf8);

typedef enum CCSWebsiteDataCategory {
  CCS_WEBSITE_DATA_SITE_DATA = 1 << 0,
  CCS_WEBSITE_DATA_CACHE = 1 << 1,
} CCSWebsiteDataCategory;

typedef struct CCSWebsiteDataRemovalV1 {
  uint32_t struct_size;
  uint32_t category_mask;
  // Null removes across the profile. A non-null canonical registrable domain,
  // IP address, or internal hostname selects that site. Registrable domains
  // include their subdomains; IP addresses and internal hostnames match only
  // themselves. Domain-scoped cache removal filters network and
  // storage-key caches, may also clear shared GPU/connection cache state, and
  // leaves some process-wide renderer/code caches for an all-profile clear.
  // Ordinary HTTP cache alone may not appear in the separately listed
  // stored-site-data domains.
  const char* registrable_domain_utf8;
  // all_time must be 0 or 1. All-time requests use 0 for the timestamp.
  // Time-bounded removal is supported only for cached resources. Chromium
  // may clear renderer and in-memory caches more broadly than this cutoff.
  double modified_since_unix_seconds;
  uint8_t all_time;
} CCSWebsiteDataRemovalV1;

// Removes unprotected web data selected by category, optional domain, and
// time. Site data includes CacheStorage; cached resources are Chromium's
// separate network/browser cache category. Extension origin data is excluded.
// Origin-keyed protected storage is excluded, but Chromium cannot distinguish
// protected-origin cookies from other cookies for the same registrable domain.
CCS_EXPORT void CCSWebsiteDataRemove(CCSContextRef context,
                                     const CCSWebsiteDataRemovalV1* removal,
                                     void* callback_data,
                                     CCSWebsiteDataStringCallback callback);

// Clears cached web resources for this normal profile. Cookies and persistent
// website storage are preserved. Private contexts are deliberately rejected.
CCS_EXPORT void CCSWebsiteDataClearCache(CCSContextRef context,
                              void* callback_data,
                              CCSWebsiteDataStringCallback callback);

// Returns a JSON array of canonical registrable domains with modeled
// unprotected HTTP(S) stored data. Pure HTTP-cache entries may not appear.
// Each item includes all of that domain's subdomains.
CCS_EXPORT void CCSWebsiteDataListSites(CCSContextRef context,
                             void* callback_data,
                             CCSWebsiteDataStringCallback callback);

// Removes unprotected HTTP(S) site data and domain-filterable cached resources
// for one canonical registrable domain and its subdomains, or one canonical
// IP address or internal hostname. Shared GPU/connection cache
// state may also be cleared; some process-wide renderer/code caches remain
// until an all-profile cache clear. Protected and extension origins are
// excluded. Private contexts and non-canonical or empty domains are rejected.
CCS_EXPORT void CCSWebsiteDataRemoveSite(CCSContextRef context,
                              const char* registrable_domain_utf8,
                              void* callback_data,
                              CCSWebsiteDataStringCallback callback);

// Returns {"cookies":[...],"skipped":n} for live, unpartitioned cookies that
// can be represented safely for an HTTPS host. `skipped` counts matching
// cookies omitted because their native metadata cannot be preserved.
CCS_EXPORT void CCSCookiesExport(CCSContextRef context,
                                 const char* https_host_utf8,
                                 void* callback_data,
                                 CCSWebsiteDataStringCallback callback);

// Validates the complete JSON cookie array before replacing representable,
// unpartitioned cookies for an HTTPS host. Partitioned cookies are preserved.
// Returns {"deleted":n,"imported":n,"rejected":n}; individual native store
// failures are reported in `rejected` without exposing cookie contents.
CCS_EXPORT void CCSCookiesReplace(CCSContextRef context,
                                  const char* https_host_utf8,
                                  const char* cookies_json_utf8,
                                  void* callback_data,
                                  CCSWebsiteDataStringCallback callback);

#if defined(__cplusplus)
}  // extern "C"

namespace cobble_chromium {

bool HasPendingWebsiteDataWork(Profile* profile);

}  // namespace cobble_chromium
#endif

#endif  // CHROME_BROWSER_UI_COBBLE_COBBLE_WEBSITE_DATA_H_
