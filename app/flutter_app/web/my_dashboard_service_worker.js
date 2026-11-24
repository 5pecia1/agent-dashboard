'use strict';

// build:web seals the worker with the paths and SHA-256 hashes of this build's
// public files. An unstamped worker remains network-only.
const BUILD = null; // Replaced by scripts/build.py.
const SCOPE = new URL(self.registration.scope);
const CACHE_PREFIX = 'agent-dashboard-shell-v2:' + encodeURIComponent(SCOPE.href) + ':';
const CACHE_NAME = CACHE_PREFIX + (BUILD ? BUILD.revision : 'unstamped');
const LEGACY_PREFIX = 'sol-app-shell-';
const fileURL = (path) => new URL(path.split('/').map(encodeURIComponent).join('/'), SCOPE).href;
const assets = new Map(Object.entries(BUILD?.files || {}).map(([path, hash]) => [fileURL(path), hash]));
const indexURL = fileURL('index.html');
const bootstrapURL = fileURL('flutter_bootstrap.js');

function cacheForbidden(headers) {
  return /(?:^|,)\s*(?:private|no-store)\s*(?:[=,]|$)/i.test(headers.get('Cache-Control') || '');
}

function publicRequest(request) {
  return request.method === 'GET' && request.cache !== 'no-store' && !cacheForbidden(request.headers) &&
    // Browser navigations and classic scripts can use include implicitly.
    // An explicit credentialed fetch() must always reach its own network response.
    (request.credentials !== 'include' || request.destination !== '') &&
    !['Authorization', 'Proxy-Authorization', 'Range', 'Cookie']
      .some(name => request.headers.has(name));
}

function publicResponse(response) {
  return response.status === 200 && response.type === 'basic' && !response.redirected &&
    !cacheForbidden(response.headers) &&
    !(response.headers.get('Vary') || '').split(',').some(name =>
      ['*', 'authorization', 'proxy-authorization', 'cookie'].includes(name.trim().toLowerCase()));
}

async function hasExpectedBytes(response, expected) {
  const bytes = await response.clone().arrayBuffer();
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
  return Array.from(digest, byte => byte.toString(16).padStart(2, '0')).join('') === expected;
}

async function shellResource(request, key) {
  let response;
  try {
    response = await fetch(request, {cache: 'no-cache'});
  } catch (error) {
    const cached = await caches.match(key, {cacheName: CACHE_NAME});
    if (cached && publicResponse(cached)) return cached;
    throw error;
  }
  try {
    const cache = await caches.open(CACHE_NAME);
    if (publicResponse(response) && await hasExpectedBytes(response, assets.get(key))) {
      await cache.put(key, response.clone());
    } else {
      // Cache API Vary matching is independent of identity. Remove the old
      // entry even if a new response changes the origin's Vary policy.
      await cache.delete(key, {ignoreVary: true});
    }
  } catch (error) {
    // Live rendering takes priority over the optional offline cache, e.g. when
    // the browser has disabled writes or run out of quota.
    console.warn('Agent Dashboard could not update its offline shell cache.');
  }
  return response;
}

self.addEventListener('install', event => {
  event.waitUntil((async () => {
    if (BUILD) {
      for (const path of ['index.html', 'flutter_bootstrap.js', 'manifest.json']) {
        const key = fileURL(path);
        await shellResource(new Request(key, {credentials: 'omit'}), key);
      }
    }
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    for (const name of await caches.keys()) {
      if (name.startsWith(CACHE_PREFIX) && name !== CACHE_NAME) {
        await caches.delete(name);
      } else if (name.startsWith(LEGACY_PREFIX)) {
        // Legacy installs always precached this exact scoped bootstrap URL.
        // Other apps on the same origin can use the old generic cache prefix.
        const legacy = await caches.open(name);
        if (await legacy.match(bootstrapURL, {ignoreVary: true})) await caches.delete(name);
      }
    }
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', event => {
  const request = event.request;
  const url = new URL(request.url);
  if (!['http:', 'https:'].includes(url.protocol) || !['GET', 'HEAD'].includes(request.method)) return;
  url.hash = ''; // Flutter session routes use fragments on the shell URL.
  const key = url.href === SCOPE.href ? indexURL : url.href;
  const shellNavigation = request.mode !== 'navigate' || key === indexURL;
  if (publicRequest(request) && shellNavigation && assets.has(key)) {
    event.respondWith(shellResource(request, key));
  } else {
    // Includes same-origin API navigations, cross-origin APIs, bearer/session
    // requests and URLs carrying query parameters. Nothing consults CacheStorage.
    event.respondWith(fetch(request, {cache: 'no-store'}));
  }
});
