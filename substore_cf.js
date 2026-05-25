const CONFIG = {
  keepOriginal: false,
  targets: [
    'www.wto.org#wto',
    'www.visa.com.sg#visa',
  ],

  // Optional: fetch target list from URLs. Each line: host[:port]#alias
  urls: [
    'https://eg1.com/',
    'https://eg2.com/',
  ],
  urlTimeout: 5000,
};

var SUPERSCRIPT_DIGITS = [
  '\u2070', '\u00B9', '\u00B2', '\u00B3', '\u2074',
  '\u2075', '\u2076', '\u2077', '\u2078', '\u2079'
];

var IPV6_RE = /^\[([^\]]+)\](?::(\d+))?$/;
var LF = String.fromCharCode(10);

var deepClone = typeof structuredClone === 'function'
  ? structuredClone
  : function (obj) { return JSON.parse(JSON.stringify(obj)); };

function toSuperscript(n) {
  return String(n).split('').map(function (d) {
    return SUPERSCRIPT_DIGITS[Number(d)];
  }).join('');
}

function parsePort(raw, ctx) {
  var port = Number(raw);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error('invalid port: ' + ctx);
  }
  return port;
}

function splitHostPort(endpoint) {
  // IPv6: [::1]:443
  if (endpoint.charCodeAt(0) === 0x5b /* '[' */) {
    var m = endpoint.match(IPV6_RE);
    if (!m) throw new Error('invalid IPv6: ' + endpoint);
    return { host: m[1], port: m[2] ? parsePort(m[2], endpoint) : undefined };
  }
  var i = endpoint.indexOf(':');
  if (i === -1) return { host: endpoint, port: undefined };
  if (endpoint.indexOf(':', i + 1) !== -1) {
    return { host: endpoint, port: undefined };
  }
  return {
    host: endpoint.slice(0, i).trim(),
    port: parsePort(endpoint.slice(i + 1), endpoint),
  };
}

function parseTargetLine(line) {
  var i = line.indexOf('#');
  if (i === -1) throw new Error('bad format: ' + line + ' (expect host[:port]#alias)');
  var endpoint = line.slice(0, i).trim();
  var alias = line.slice(i + 1).trim();
  if (!endpoint) throw new Error('missing host: ' + line);
  if (!alias) throw new Error('missing alias: ' + line);
  var hp = splitHostPort(endpoint);
  return { host: hp.host, port: hp.port, alias: alias };
}

function parseTargetText(text) {
  var out = [];
  var lines = String(text).split(LF);
  for (var k = 0; k < lines.length; k++) {
    var line = lines[k].trim(); // trim drops the trailing \r as well
    if (!line) continue;
    if (line.charAt(0) === '#') continue;
    if (line.indexOf('#') === -1) continue;
    try {
      out.push(parseTargetLine(line));
    } catch (_) { /* skip bad line */ }
  }
  return out;
}

var STATIC_TARGETS = (Array.isArray(CONFIG.targets) ? CONFIG.targets : [])
  .map(function (s) { return String(s).trim(); })
  .filter(Boolean)
  .map(parseTargetLine);

var HAS_URLS = Array.isArray(CONFIG.urls) && CONFIG.urls.some(function (u) {
  return String(u || '').trim();
});

if (!STATIC_TARGETS.length && !HAS_URLS) {
  throw new Error('CONFIG.targets and CONFIG.urls cannot both be empty');
}

function injectAlias(name, alias) {
  if (!name) return alias;
  var i = name.indexOf('_');
  return i === -1
    ? name + '-' + alias
    : name.slice(0, i) + '-' + alias + name.slice(i);
}

function cloneWithTarget(proxy, target) {
  var c = deepClone(proxy);
  c.server = target.host;
  if (target.port !== undefined) c.port = target.port;
  c.name = injectAlias(proxy.name, target.alias);
  return c;
}

function dedupAliases(targets) {
  var counts = new Map();
  for (var i = 0; i < targets.length; i++) {
    var a = targets[i].alias;
    counts.set(a, (counts.get(a) || 0) + 1);
  }
  var idx = new Map();
  return targets.map(function (t) {
    if ((counts.get(t.alias) || 0) <= 1) return t;
    var j = idx.get(t.alias) || 0;
    idx.set(t.alias, j + 1);
    return { host: t.host, port: t.port, alias: t.alias + toSuperscript(j) };
  });
}

async function httpGetText(url) {
  // Sub-Store provides $substore; some setups also expose $.
  var $api =
    (typeof $substore !== 'undefined' && $substore) ? $substore :
    (typeof $ !== 'undefined' && $) ? $ : null;

  if ($api && $api.http && typeof $api.http.get === 'function') {
    var res = await $api.http.get({ url: url, timeout: CONFIG.urlTimeout });
    if (!res) return '';
    if (res.body !== undefined) return res.body;
    if (res.data !== undefined) return res.data;
    if (res.rawBody !== undefined) return res.rawBody;
    return '';
  }
  if (typeof fetch === 'function') {
    var r = await fetch(url);
    return await r.text();
  }
  throw new Error('no HTTP client available in this runtime');
}

async function fetchTargetsFromUrls(urls) {
  var list = await Promise.all(urls.map(async function (u) {
    try {
      var text = await httpGetText(u);
      return parseTargetText(text);
    } catch (e) {
      if (typeof console !== 'undefined') {
        console.log('[targets-url] fetch failed: ' + u + ' - ' + ((e && e.message) || e));
      }
      return [];
    }
  }));
  var result = [];
  for (var i = 0; i < list.length; i++) {
    for (var j = 0; j < list[i].length; j++) result.push(list[i][j]);
  }
  return result;
}

async function operator(proxies, targetPlatform, context) {
  if (!proxies) proxies = [];
  if (!Array.isArray(proxies)) return proxies;

  var targets = STATIC_TARGETS.slice();
  var urls = (Array.isArray(CONFIG.urls) ? CONFIG.urls : [])
    .map(function (u) { return String(u || '').trim(); })
    .filter(Boolean);
  if (urls.length) {
    var fetched = await fetchTargetsFromUrls(urls);
    for (var i = 0; i < fetched.length; i++) targets.push(fetched[i]);
  }

  if (!targets.length) return proxies;

  targets = dedupAliases(targets);

  var keep = Boolean(CONFIG.keepOriginal);
  var perProxy = targets.length + (keep ? 1 : 0);
  var output = new Array(proxies.length * perProxy);
  var n = 0;

  for (var p = 0; p < proxies.length; p++) {
    var proxy = proxies[p];
    if (!proxy || !proxy.server) {
      output[n++] = proxy;
      continue;
    }
    if (keep) output[n++] = proxy;
    for (var t = 0; t < targets.length; t++) {
      output[n++] = cloneWithTarget(proxy, targets[t]);
    }
  }

  output.length = n;
  return output;
}
