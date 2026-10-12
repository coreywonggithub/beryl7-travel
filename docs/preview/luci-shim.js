/*
 * Stand-in for just enough of LuCI to run the travel panel in a normal browser.
 *
 * panel.js is not copied or edited here. It is loaded the way LuCI loads a
 * view: the file is fetched as text, its "require" lines are read, and the
 * rest is evaluated as the body of a function that receives (window,
 * document, L, view, rpc, poll, ui) and returns the view class. The class is
 * then instantiated, which loads and renders the view into #view.
 *
 * Differences from the real thing that matter when reading a bug report:
 *  - E() is a re-implementation with LuCI's quirks kept on purpose: a bare
 *    string child is parsed as HTML, and null items inside a child array turn
 *    into the text "null". If the panel trips over either, it shows here.
 *  - The class factory is evaluated with an indirect eval, so panel.js sees
 *    only real globals plus the arguments above, not this file's variables.
 *  - The router is a mock (TravelMock, at the bottom of this file).
 *
 * Opening index.html straight from the disk (file://) works for everything
 * except reading panel.js as text, which browsers block. In that case the
 * page asks for the file once (see localFilePicker).
 */
(function() {
'use strict';

var RESOURCE_BASE = '../../package/luci-app-travel/htdocs/luci-static/resources';

/* ------------------------------------------------------------------ *
 *  Class system (same shape as LuCI.baseclass)
 * ------------------------------------------------------------------ */

var classIndex = 0;

var Class = Object.assign(function() {}, {
	extend: function(properties) {
		var props = {
			__id__: { value: classIndex },
			__base__: { value: this.prototype },
			__name__: { value: properties.__name__ != null ? properties.__name__ : 'anonymous' + (classIndex++) }
		};

		var Ctor = function() {
			if (!(this instanceof Ctor))
				throw new TypeError('Constructor must not be called without "new"');

			if (typeof(this.__init__) == 'function')
				this.__init__.apply(this, arguments);
		};

		for (var key in properties)
			if (!props[key] && properties.hasOwnProperty(key))
				props[key] = { value: properties[key], writable: true };

		Ctor.prototype = Object.create(this.prototype, props);
		Ctor.prototype.constructor = Ctor;
		Object.assign(Ctor, this);

		return Ctor;
	},

	singleton: function(properties) {
		return Class.extend(properties).instantiate(Array.prototype.slice.call(arguments, 1));
	},

	instantiate: function(args) {
		return new (Function.prototype.bind.apply(this, [ null ].concat(args)))();
	},

	isSubclass: function(v) {
		return (typeof(v) == 'function' && v.prototype instanceof this);
	},

	prototype: {}
});

/* ------------------------------------------------------------------ *
 *  dom / E()
 * ------------------------------------------------------------------ */

var domParser = new DOMParser();

var dom = {
	registry: {},

	elem: function(e) {
		return (e != null && typeof(e) == 'object' && 'nodeType' in e);
	},

	parse: function(s) {
		try { return domParser.parseFromString(s, 'text/html').body.firstChild; }
		catch (e) { return null; }
	},

	matches: function(node, selector) {
		return this.elem(node) && node.matches ? node.matches(selector) : false;
	},

	parent: function(node, selector) {
		return (this.elem(node) && node.closest) ? node.closest(selector) : null;
	},

	append: function(node, children) {
		if (!this.elem(node))
			return null;

		if (Array.isArray(children)) {
			for (var i = 0; i < children.length; i++)
				if (this.elem(children[i]))
					node.appendChild(children[i]);
				else if (children !== null && children !== undefined)
					node.appendChild(document.createTextNode('' + children[i]));

			return node.lastChild;
		}
		else if (typeof(children) === 'function') {
			return this.append(node, children(node));
		}
		else if (this.elem(children)) {
			return node.appendChild(children);
		}
		else if (children !== null && children !== undefined) {
			node.innerHTML = '' + children;
			return node.lastChild;
		}

		return null;
	},

	content: function(node, children) {
		if (!this.elem(node))
			return null;

		while (node.firstChild)
			node.removeChild(node.firstChild);

		return this.append(node, children);
	},

	attr: function(node, key, val) {
		if (!this.elem(node))
			return null;

		var attr = null;

		if (typeof(key) === 'object' && key !== null)
			attr = key;
		else if (typeof(key) === 'string')
			attr = {}, attr[key] = val;

		for (key in attr) {
			if (!attr.hasOwnProperty(key) || attr[key] == null)
				continue;

			switch (typeof(attr[key])) {
			case 'function':
				node.addEventListener(key, attr[key]);
				break;

			case 'object':
				node.setAttribute(key, JSON.stringify(attr[key]));
				break;

			default:
				node.setAttribute(key, attr[key]);
			}
		}
	},

	create: function() {
		var html = arguments[0], attr = arguments[1], data = arguments[2], elem;

		if (!(attr instanceof Object) || Array.isArray(attr))
			data = attr, attr = null;

		if (Array.isArray(html)) {
			elem = document.createDocumentFragment();

			for (var i = 0; i < html.length; i++)
				elem.appendChild(this.create(html[i]));
		}
		else if (this.elem(html)) {
			elem = html;
		}
		else if (html.charCodeAt(0) === 60) {
			elem = this.parse(html);
		}
		else {
			elem = document.createElement(html);
		}

		if (!elem)
			return null;

		this.attr(elem, attr);
		this.append(elem, data);

		return elem;
	}
};

function E() { return dom.create.apply(dom, arguments); }

/* ------------------------------------------------------------------ *
 *  Strings: _() and String.prototype.format (%s, %d, %%)
 * ------------------------------------------------------------------ */

function _(s) { return s; }

String.prototype.format = function() {
	var args = arguments, n = 0;

	return this.replace(/%(%|s|d)/g, function(m, t) {
		if (t == '%')
			return '%';

		var v = args[n++];

		return (t == 'd') ? String(Math.floor(+v || 0)) : String(v);
	});
};

/* ------------------------------------------------------------------ *
 *  poll (same timing rules as LuCI.poll: one tick per second, a job runs
 *  when tick % interval == 0 and is skipped while its last run is pending)
 * ------------------------------------------------------------------ */

var Poll = {
	queue: [],
	tick: 0,
	timer: null,

	add: function(fn, interval) {
		if (interval == null || interval <= 0)
			interval = L.env.pollinterval || 5;

		if (isNaN(interval) || typeof(fn) != 'function')
			throw new TypeError('Invalid argument to LuCI.poll.add()');

		for (var i = 0; i < this.queue.length; i++)
			if (this.queue[i].fn === fn)
				return false;

		this.queue.push({ r: true, i: interval >>> 0, fn: fn });

		return true;
	},

	remove: function(fn) {
		var len = this.queue.length;

		for (var i = len; i > 0; i--)
			if (this.queue[i - 1].fn === fn)
				this.queue.splice(i - 1, 1);

		return this.queue.length != len;
	},

	step: function() {
		Poll.queue.forEach(function(e) {
			if ((Poll.tick % e.i) != 0 || !e.r)
				return;

			e.r = false;
			Promise.resolve(e.fn()).finally(function() { e.r = true; });
		});

		Poll.tick = (Poll.tick + 1) % Math.pow(2, 32);
	},

	start: function() {
		if (this.active())
			return false;

		this.tick = 0;
		this.timer = window.setInterval(this.step, 1000);
		this.step();

		return true;
	},

	stop: function() {
		if (!this.active())
			return false;

		window.clearInterval(this.timer);
		this.timer = null;

		return true;
	},

	active: function() { return this.timer != null; }
};

/* ------------------------------------------------------------------ *
 *  view (same flow as LuCI.view: spinner, load, render, insert)
 * ------------------------------------------------------------------ */

var View = Class.extend({
	__name__: 'LuCI.view',

	__init__: function() {
		var self = this;
		var vp = document.getElementById('view');

		dom.content(vp, E('div', { 'class': 'spinning' }, _('Loading view…')));

		var ready = L.loaded
			? Promise.resolve()
			: new Promise(function(resolve) { document.addEventListener('luci-loaded', resolve, { once: true }); });

		return ready
			.then(function() { return self.load(); })
			.then(function(data) { return self.render(data); })
			.then(function(nodes) {
				var vp = document.getElementById('view');

				dom.content(vp, nodes);
				dom.append(vp, self.addFooter());
			})
			.catch(function(err) { L.error(err); });
	},

	load: function() {},
	render: function() {},
	handleSave: function() { return Promise.resolve(); },
	handleSaveApply: function() { return Promise.resolve(); },
	handleReset: function() { return Promise.resolve(); },

	/* Views that set all three handlers to null get no footer, like in LuCI. */
	addFooter: function() {
		var footer = E([]);

		if (this.handleSaveApply || this.handleSave || this.handleReset)
			footer.appendChild(E('div', { 'class': 'cbi-page-actions' }, [
				this.handleSaveApply ? E('button', { 'class': 'cbi-button cbi-button-apply' }, [ 'Save & Apply' ]) : '', ' ',
				this.handleSave ? E('button', { 'class': 'cbi-button cbi-button-save' }, [ 'Save' ]) : '', ' ',
				this.handleReset ? E('button', { 'class': 'cbi-button cbi-button-reset' }, [ 'Reset' ]) : ''
			]));

		return footer;
	}
});

/* ------------------------------------------------------------------ *
 *  ui (the parts the panel may call)
 * ------------------------------------------------------------------ */

var modalDiv = null;

var UI = {
	showModal: function(title, children) {
		if (!modalDiv) {
			modalDiv = E('div', { id: 'modal_overlay' }, [ E('div', { 'class': 'modal', role: 'dialog', 'aria-modal': 'true' }) ]);
			document.body.appendChild(modalDiv);
		}

		var dlg = modalDiv.firstElementChild;

		dom.content(dlg, E('h4', {}, [ title ]));
		dom.append(dlg, children);
		document.body.classList.add('modal-overlay-active');

		return dlg;
	},

	hideModal: function() {
		document.body.classList.remove('modal-overlay-active');
	},

	addNotification: function(title, children) {
		var classes = Array.prototype.slice.call(arguments, 2);
		var mc = document.querySelector('#maincontent') || document.body;
		var msg = E('div', { 'class': 'alert-message fade-in' }, [
			E('div', {}),
			E('button', { 'class': 'btn', click: function(ev) { msg.parentNode && msg.parentNode.removeChild(msg); } }, [ 'Dismiss' ])
		]);

		if (title != null)
			dom.append(msg.firstElementChild, E('h4', {}, [ title ]));

		dom.append(msg.firstElementChild, children);
		classes.forEach(function(c) { msg.classList.add(c); });
		mc.insertBefore(msg, mc.firstElementChild);

		return msg;
	},

	createHandlerFn: function(ctx, fn) {
		var args = Array.prototype.slice.call(arguments, 2);

		if (typeof(fn) == 'string')
			fn = ctx[fn];

		return function() {
			var t = arguments[args.length].currentTarget;

			t.classList.add('spinning');
			t.disabled = true;

			Promise.resolve(fn.apply(ctx, arguments)).finally(function() {
				t.classList.remove('spinning');
				t.disabled = false;
			});
		};
	},

	showIndicator: function() {},
	hideIndicator: function() {}
};

/* ------------------------------------------------------------------ *
 *  rpc.declare (same parameter, expect and filter rules as LuCI.rpc)
 * ------------------------------------------------------------------ */

var RPC = {
	declare: function(options) {
		var type = Object.prototype.toString;

		return function() {
			var args = Array.prototype.slice.call(arguments);

			return new Promise(function(resolve, reject) {
				var params = {}, off = 0;

				if (Array.isArray(options.params)) {
					for (off = 0; off < options.params.length; off++)
						params[options.params[off]] = args[off];
				}
				else if (options.params && typeof(options.params) === 'object') {
					var argObj = args[0];

					if (argObj && typeof(argObj) === 'object')
						for (var key in options.params)
							if (key in argObj)
								params[key] = argObj[key];

					off = 1;
				}

				var priv = [ undefined, undefined ];

				for (; off < args.length; off++)
					priv.push(args[off]);

				/* What goes over the wire: undefined values are dropped, like JSON.stringify does. */
				var wire = JSON.parse(JSON.stringify(params));

				TravelMock.call(options.object, options.method, wire).then(function(reply) {
					var ret = null;

					if (Array.isArray(reply))
						ret = (reply.length > 1) ? reply[1] : reply[0];

					if (options.expect) {
						for (var k in options.expect) {
							if (ret != null && k != '')
								ret = ret[k];

							if (ret == null || type.call(ret) != type.call(options.expect[k]))
								ret = options.expect[k];

							break;
						}
					}

					if (typeof(options.filter) == 'function') {
						priv[0] = ret;
						priv[1] = params;
						ret = options.filter.apply(RPC, priv);
					}

					resolve(ret);
				}, reject);
			});
		};
	},

	addInterceptor: function(fn) { return fn; },
	removeInterceptor: function() { return false; }
};

/* ------------------------------------------------------------------ *
 *  L (the LuCI object) and the class loader
 * ------------------------------------------------------------------ */

var classes = {
	baseclass: Class,
	dom: dom,
	poll: Poll,
	view: View,
	rpc: RPC,
	ui: UI
};

/* Same rules as LuCI.path(): only plain path parts survive, others are dropped silently. */
function joinPath(prefix, parts) {
	var url = [ prefix ];

	for (var i = 0; i < parts.length; i++) {
		var part = parts[i];

		if (Array.isArray(part))
			url.push(joinPath('', part));
		else if (/^(?:[a-zA-Z0-9_.%,;-]+\/)*[a-zA-Z0-9_.%,;-]+$/.test(part) || /^\?[a-zA-Z0-9_.%=&;-]+$/.test(part))
			url.push(part.charAt(0) == '?' ? part : '/' + part);
	}

	if (url.length === 1)
		url.push('/');

	return url.join('');
}

var L = {
	env: {
		pollinterval: 5,
		sessionid: '00000000000000000000000000000000',
		scriptname: '/cgi-bin/luci',
		requestpath: [ 'admin', 'services', 'travel' ],
		base_url: RESOURCE_BASE
	},

	loaded: false,

	resource: function() { return joinPath(RESOURCE_BASE, arguments); },
	url: function() { return joinPath('/cgi-bin/luci', arguments); },
	bind: function(fn, self) { return Function.prototype.bind.apply(fn, [ self ].concat(Array.prototype.slice.call(arguments, 2))); },
	isObject: function(v) { return (v != null && typeof(v) == 'object'); },
	resolveDefault: function(p, d) { return Promise.resolve(p).catch(function() { return d; }); },
	dom: dom,
	ui: UI,
	rpc: RPC,
	poll: Poll,

	error: function(err) {
		var e = (err instanceof Error) ? err : new Error(String(err));

		if (window.console)
			console.error(e);

		UI.addNotification(e.name || 'Runtime error', E('pre', {}, [ e.message ]), 'danger');

		throw e;
	},

	raise: function(type, fmt) {
		var e = new Error(String.prototype.format.apply(fmt || 'Unspecified error', Array.prototype.slice.call(arguments, 2)));

		e.name = type || 'Error';

		throw e;
	},

	/* Class loader: same steps as LuCI.require(). */
	require: function(name, from) {
		from = from || [];

		if (classes[name] != null) {
			if (from.indexOf(name) != -1)
				L.raise('DependencyError', 'Circular dependency: class "%s" depends on "%s"', name, from.join('" which depends on "'));

			return Promise.resolve(classes[name]);
		}

		var url = L.env.base_url + '/' + name.replace(/\./g, '/') + '.js';

		from = [ name ].concat(from);

		classes[name] = loadSource(url, name).then(function(res) {
			var source = res.text;
			var requirematch = /^require[ \t]+(\S+)(?:[ \t]+as[ \t]+([a-zA-Z_]\S*))?$/;
			var strictmatch = /^use[ \t]+strict$/;
			var depends = [];
			var args = '';

			/* find the leading 'require x' statements, exactly like LuCI does */
			for (var i = 0, off = -1, prev = -1, quote = -1, comment = -1, esc = false; i < source.length; i++) {
				var chr = source.charCodeAt(i);

				if (esc) {
					esc = false;
				}
				else if (comment != -1) {
					if ((comment == 47 && chr == 10) || (comment == 42 && prev == 42 && chr == 47))
						comment = -1;
				}
				else if ((chr == 42 || chr == 47) && prev == 47) {
					comment = chr;
				}
				else if (chr == 92) {
					esc = true;
				}
				else if (chr == quote) {
					var s = source.substring(off, i), m = requirematch.exec(s);

					if (m) {
						var dep = m[1], as = m[2] || dep.replace(/[^a-zA-Z0-9_]/g, '_');

						depends.push(L.require(dep, from));
						args += ', ' + as;
					}
					else if (!strictmatch.exec(s)) {
						break;
					}

					off = -1;
					quote = -1;
				}
				else if (quote == -1 && (chr == 34 || chr == 39)) {
					off = i + 1;
					quote = chr;
				}

				prev = chr;
			}

			return Promise.all(depends).then(function(instances) {
				var factory, cls;

				try {
					factory = (0, eval)('(function(window, document, L' + args + ') { ' + source + ' })\n\n//# sourceURL=' + res.url + '\n');
				}
				catch (error) {
					L.raise('SyntaxError', '%s\n  in %s', error.message, res.url);
				}

				cls = factory.apply(factory, [ window, document, L ].concat(instances));

				if (!Class.isSubclass(cls))
					L.raise('TypeError', '"%s" factory yields invalid constructor', name);

				var instance = new cls();

				classes[name] = instance;

				return instance;
			});
		});

		return classes[name];
	}
};

window.L = L;
window.E = E;
window._ = _;

/* ------------------------------------------------------------------ *
 *  Reading class files: XHR like LuCI, plus a way out for file://
 * ------------------------------------------------------------------ */

function loadSource(url, name) {
	return new Promise(function(resolve, reject) {
		var xhr = new XMLHttpRequest();

		xhr.open('GET', url);
		xhr.onload = function() {
			if (xhr.status === 200 || (xhr.status === 0 && xhr.responseText))
				resolve({ text: xhr.responseText, url: xhr.responseURL || url });
			else
				reject(new Error('HTTP error ' + xhr.status + ' while loading class file "' + url + '"'));
		};
		xhr.onerror = function() { reject(new Error('Could not load class file "' + url + '"')); };
		xhr.send();
	}).catch(function(err) {
		if (window.location.protocol !== 'file:')
			throw err;

		return localFilePicker(url, name);
	});
}

/* Browsers refuse to let a page read a sibling file from disk. So, only for
 * file:// and only when the read failed, ask for the file once. */
function localFilePicker(url, name) {
	return new Promise(function(resolve, reject) {
		var wanted = url.split('/').pop();
		var path = 'package/luci-app-travel/htdocs/luci-static/resources/' + name.replace(/\./g, '/') + '.js';
		var input = E('input', { type: 'file', accept: '.js' });
		var err = E('p', { 'class': 'shim-error' });
		var box = E('div', { 'class': 'shim-card' }, [
			E('h3', {}, [ 'This browser will not read files from your disk' ]),
			E('p', {}, [ 'The preview has to read ' + wanted + ' as text, and browsers block that for pages opened from a file. Either choose the file here, once per page load:' ]),
			E('pre', {}, [ path ]),
			E('p', {}, [ input ]),
			E('p', {}, [ 'or serve the folder and open the page over http, which needs no clicking at all:' ]),
			E('pre', {}, [ 'cd <repository folder>\npython3 -m http.server 8765 --bind 127.0.0.1\nthen open http://127.0.0.1:8765/docs/preview/index.html' ]),
			err
		]);

		input.addEventListener('change', function() {
			var file = input.files && input.files[0];

			if (!file)
				return;

			if (file.name !== wanted) {
				err.textContent = 'That is ' + file.name + '. Choose ' + wanted + ' from ' + path;
				return;
			}

			var rd = new FileReader();

			rd.onload = function() { resolve({ text: String(rd.result), url: 'file:///' + file.name }); };
			rd.onerror = function() { reject(new Error('Could not read ' + file.name)); };
			rd.readAsText(file);
		});

		dom.content(document.getElementById('view'), box);
	});
}

/* ------------------------------------------------------------------ *
 *  The mock router
 * ------------------------------------------------------------------ */

var TravelMock = (function() {
	var MODES = [ 'direct', 'exitnode', 'wireguard', 'nikki' ];

	function now() { return Math.floor(Date.now() / 1000); }
	function clone(o) { return JSON.parse(JSON.stringify(o)); }
	function delay(ms) { return new Promise(function(r) { window.setTimeout(r, ms); }); }
	function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)); }
	function ok(extra) { return Object.assign({ ok: true }, extra || {}); }
	function fail(msg) { return { ok: false, error: msg }; }

	var sim = { unreachable: false, uplinkWifi: true };
	var calls = [];
	var scanOverride = null;

	var tsNodes = [
		{ name: 'home-nas', label: 'Office', ip: '100.64.0.11', online: true, active: false },
		{ name: 'backup-nas', label: 'TW home', ip: '100.64.0.12', online: true, active: false },
		{ name: 'office-mini', label: 'Office 2', ip: '100.64.0.13', online: true, active: false }
	];

	var state;

	function fresh() {
		var t = now();

		return {
			hostname: 'beryl7',
			mode: { desired: 'exitnode', active: 'direct', hold: 'portal', exit_node: '100.64.0.11', wg: 'wg_office', error: '' },
			'switch': { region: 'world', world_mode: 'exitnode', position: 'on', on: 'exitnode', off: 'direct' },
			internet: { online: true, uplink: 'trm_wwan', failover: false },
			uplinks: [
				{ name: 'wan', kind: 'ethernet', label: 'Ethernet', present: true, up: false, online: false, metric: 10, detail: 'No cable' },
				{ name: 'trm_wwan', kind: 'wifi', label: 'Wi-Fi', present: true, up: true, online: true, metric: 20,
				  ssid: 'Guest_WiFi', band: '5g', channel: 44, signal: -61, quality: 78 },
				{ name: 'tether', kind: 'phone', label: 'Phone over USB', present: false, up: false, online: false, metric: 30,
				  detail: 'Plug in and unlock your phone' }
			],
			portal: { state: 'detected', host: 'login.guestnet.example', url: 'http://login.guestnet.example/login', since: t - 300 },
			speed: { rx_bps: 12400000, tx_bps: 1800000, uplink: 'trm_wwan' },
			wifi: {
				ssid: 'Beryl7', country: 'DE', country_detected: 'DE', country_source: 'nearby Wi-Fi',
				radios: [
					{ band: '2g', channel: 6, auto: true, locked: false },
					{ band: '5g', channel: 44, auto: false, locked: true }
				]
			},
			devices: [
				{ mac: 'aa:bb:cc:dd:ee:ff', name: 'iPhone', ip: '172.31.77.23', band: '5g', signal: -48, blocked: false, online: true, rx_bytes: 1200000000, tx_bytes: 90000000 },
				{ mac: '3c:22:fb:0a:91:5e', name: "MacBook-Air", ip: '172.31.77.31', band: '5g', signal: -57, blocked: false, online: true, rx_bytes: 3400000000, tx_bytes: 410000000 },
				{ mac: 'f0:27:2d:6b:14:c8', name: '', ip: '172.31.77.44', band: '2g', signal: -71, blocked: false, online: true, rx_bytes: 18000000, tx_bytes: 2100000 },
				{ mac: '74:d4:35:81:0c:2a', name: 'Kindle', ip: '172.31.77.52', band: '2g', signal: -66, blocked: true, online: true, rx_bytes: 0, tx_bytes: 0 },
				/* like the real router: wired clients are never "online" (only Wi-Fi associations are), and have no band */
				{ mac: 'b8:27:eb:11:22:33', name: 'Apple-TV', ip: '172.31.77.60', band: null, signal: null, blocked: false, online: false, rx_bytes: 2100000000, tx_bytes: 30000000 }
			],
			tailscale: { state: 'Running', ip: '100.64.0.2', name: 'beryl7', auth_url: '', exit_nodes: clone(tsNodes) },
			wireguard: [
				{ name: 'wg_office', label: 'Office', up: false, endpoint: 'office.example.com:51820', handshake: 0 }
			],
			nikki: { installed: true, running: false },
			hide_router: true,

			/* internal, never sent */
			flags: { joining: false, noInternet: false, autoCountry: true },
			saved: [
				{ ssid: 'Guest_WiFi', band: '5g', enabled: true },
				{ ssid: 'Home_Office', band: '2g', enabled: true }
			]
		};
	}

	state = fresh();

	function node(ip) {
		return state.tailscale.exit_nodes.filter(function(n) { return n.ip === ip; })[0] || null;
	}

	function uplink(name) {
		return state.uplinks.filter(function(u) { return u.name === name; })[0];
	}

	/* Works out what the router would report from the settings and the simulated conditions. */
	function recompute() {
		var s = state, m = s.mode;
		var wifi = uplink('trm_wwan');
		var f = s.flags;

		if (!f.joining) {
			var up = !!(sim.uplinkWifi && wifi.ssid);

			wifi.up = up;
			wifi.online = up && !f.noInternet;

			if (!wifi.ssid)
				wifi.detail = 'Choose a Wi-Fi network';
			else if (!sim.uplinkWifi)
				wifi.detail = 'Connecting…';
			else
				delete wifi.detail;
		}

		var onlineUplinks = s.uplinks.filter(function(u) { return u.online; }).sort(function(a, b) { return a.metric - b.metric; });

		s.internet.online = onlineUplinks.length > 0;
		s.internet.uplink = onlineUplinks.length ? onlineUplinks[0].name : '';

		s.wifi.radios.forEach(function(r) {
			r.locked = !!(wifi.up && wifi.band === r.band);

			if (r.locked)
				r.channel = wifi.channel;
		});

		m.error = '';
		m.hold = '';
		m.active = m.desired;

		if (s.portal.state === 'detected' && m.desired !== 'direct') {
			m.hold = 'portal';
			m.active = 'direct';
		}
		else if (m.desired === 'exitnode') {
			if (s.tailscale.state !== 'Running') {
				m.error = 'Tailscale is not logged in';
				m.active = 'direct';
			}
			else if (!node(m.exit_node) || !node(m.exit_node).online) {
				m.error = 'The exit node is not reachable';
				m.active = 'direct';
			}
		}
		else if (m.desired === 'wireguard') {
			if (!s.wireguard.filter(function(p) { return p.name === m.wg; })[0]) {
				m.error = 'Choose a VPN profile first.';
				m.active = 'direct';
			}
		}
		else if (m.desired === 'nikki') {
			if (!s.nikki.installed) {
				m.error = 'nikki is not installed';
				m.active = 'direct';
			}
		}

		if (!s.internet.online && m.active !== 'direct' && !m.error)
			m.error = 'Waiting for an internet source';

		s.tailscale.exit_nodes.forEach(function(n) { n.active = (m.active === 'exitnode' && n.ip === m.exit_node); });
		s.wireguard.forEach(function(p) {
			p.up = (m.active === 'wireguard' && m.wg === p.name);
			p.handshake = p.up ? now() - 9 : 0;
		});
		s.nikki.running = (m.active === 'nikki');
	}

	var speedNow = { rx: 12400000, tx: 1800000 };

	function traffic() {
		var online = state.internet.online;

		if (!online) {
			speedNow.rx = speedNow.tx = 0;
		}
		else {
			if (speedNow.rx < 1000)
				speedNow.rx = 3e6, speedNow.tx = 5e5;

			speedNow.rx = clamp(speedNow.rx * (0.7 + Math.random() * 0.6) + (Math.random() < 0.15 ? 9e6 : 0), 4e5, 48e6);
			speedNow.tx = clamp(speedNow.tx * (0.7 + Math.random() * 0.6), 6e4, 6e6);
		}

		state.speed.rx_bps = Math.round(speedNow.rx);
		state.speed.tx_bps = Math.round(speedNow.tx);
		state.speed.uplink = state.internet.uplink;

		state.devices.forEach(function(d) {
			if (d.blocked)
				return;

			d.rx_bytes += Math.round(speedNow.rx / 8 * 5 * (d.band === '5g' ? 0.35 : 0.05) * Math.random());
			d.tx_bytes += Math.round(speedNow.tx / 8 * 5 * (d.band === '5g' ? 0.35 : 0.05) * Math.random());
		});
	}

	function status() {
		var s = state;

		recompute();
		traffic();

		return clone({
			time: now(),
			hostname: s.hostname,
			mode: s.mode,
			'switch': s['switch'],
			internet: s.internet,
			uplinks: s.uplinks,
			portal: s.portal,
			speed: s.speed,
			wifi: s.wifi,
			devices: s.devices,
			tailscale: s.tailscale,
			wireguard: s.wireguard,
			nikki: s.nikki,
			hide_router: s.hide_router
		});
	}

	/* ---- fake scan ---- */

	function scanList() {
		var list = scanOverride || [
			{ ssid: 'Guest_WiFi', bssid: '9c:1e:95:20:11:a4', band: '5g', channel: 44, quality: 78, security: 'psk' },
			{ ssid: 'Airport_Free', bssid: '9c:1e:95:20:11:a5', band: '2g', channel: 1, quality: 66, security: 'open' },
			{ ssid: 'Cafe Corner 5G', bssid: 'b0:be:76:42:7c:0d', band: '5g', channel: 36, quality: 52, security: 'sae' },
			{ ssid: 'Campus_Staff', bssid: '9c:1e:95:20:2f:11', band: '5g', channel: 149, quality: 41, security: 'enterprise' },
			{ ssid: 'Neighbour_2044', bssid: 'e4:f4:c6:0d:ee:31', band: '2g', channel: 11, quality: 23, security: 'psk' }
		];

		return clone(list).map(function(n) {
			n.saved = state.saved.some(function(s) { return s.ssid === n.ssid; });
			return n;
		});
	}

	/* ---- commands ---- */

	function macRandom() {
		var b = [];

		for (var i = 0; i < 6; i++)
			b.push(Math.floor(Math.random() * 256));

		b[0] = (b[0] & 0xfc) | 0x02;

		return b.map(function(x) { return ('0' + x.toString(16)).slice(-2); }).join(':');
	}

	var handlers = {
		status: function() { return status(); },

		set_mode: function(p) {
			var m = state.mode;

			if (MODES.indexOf(p.mode) < 0)
				return fail('That mode is not known.');

			if (p.mode === 'nikki' && !state.nikki.installed)
				return fail('nikki is not installed on this router.');

			if (p.mode === 'exitnode') {
				var ip = p.exit_node || m.exit_node;

				if (!ip || !node(ip))
					return fail('Pick an exit node from your tailnet.');

				m.exit_node = ip;
			}

			if (p.mode === 'wireguard') {
				var name = p.wg || m.wg;

				if (!name || !state.wireguard.filter(function(x) { return x.name === name; })[0])
					return fail('Choose a VPN profile first.');

				m.wg = name;
			}

			m.desired = p.mode;
			recompute();

			return ok();
		},

		set_switch_map: function(p) {
			if (MODES.indexOf(p.on) < 0 || MODES.indexOf(p.off) < 0)
				return fail('Unknown mode.');

			state['switch'].on = p.on;
			state['switch'].off = p.off;

			return ok();
		},

		/* Same rules as the plugin: China means on = nikki; the rest of the world means
		 * on = world_mode (kept from last time when not sent); off is always direct. */
		set_region: function(p) {
			var sw = state['switch'];

			if (p.region === 'china') {
				sw.on = 'nikki';
			}
			else if (p.region === 'world') {
				var wm = p.world_mode || sw.world_mode;

				if (wm !== 'exitnode' && wm !== 'wireguard')
					return fail('Choose Tailscale exit or VPN.');

				sw.world_mode = wm;
				sw.on = wm;
			}
			else {
				return fail('Choose China or rest of the world.');
			}

			sw.region = p.region;
			sw.off = 'direct';

			/* like `travel/switch current`: with the slider on or off right now, the new meaning applies at once */
			if (sw.position === 'on' || sw.position === 'off')
				state.mode.desired = sw[sw.position];

			recompute();

			return ok();
		},

		wifi_scan: function(p) {
			return delay(1000).then(function() {
				var list = scanList().filter(function(n) { return p.band === 'all' || !p.band || n.band === p.band; });

				return ok({ networks: list });
			});
		},

		wifi_join: function(p) {
			if (!p.ssid)
				return fail('Enter the network name first.');

			if (String(p.ssid).length > 32)
				return fail('That network name is too long.');

			if (p.security !== 'open' && p.security !== 'owe' && p.security !== 'enterprise') {
				/* the router always wants the password, even for a saved network */
				var kl = String(p.key || '').length;

				if (kl < 8 || kl > 63)
					return fail('The password must be 8 to 63 characters.');
			}

			if (p.security === 'enterprise' && !(p.identity && p.password))
				return fail('Enter the username and password.');

			var found = scanList().filter(function(n) { return n.ssid === p.ssid; })[0];
			var band = p.band || (found && found.band) || '2g';

			if (!state.saved.some(function(s) { return s.ssid === p.ssid; }))
				state.saved.push({ ssid: p.ssid, band: band, enabled: true });

			var u = uplink('trm_wwan');

			u.ssid = p.ssid;
			u.band = band;
			u.channel = found ? found.channel : (band === '5g' ? 36 : 6);
			u.quality = found ? found.quality : 55;
			u.signal = -70;
			u.up = false;
			u.online = false;
			u.detail = 'Connecting…';
			state.flags.joining = true;

			window.setTimeout(function() {
				state.flags.joining = false;

				/* An open network often puts a login page in the way; a password network does not. */
				if (p.ssid === 'Airport_Free') {
					state.flags.noInternet = true;
					state.portal = { state: 'detected', host: 'welcome.airport.example', url: 'http://welcome.airport.example/start', since: now() };
				}
				else {
					state.flags.noInternet = false;
					state.portal = { state: 'none', host: '', url: '', since: 0 };
				}
			}, 3200);

			return delay(500).then(function() { return ok(); });
		},

		wifi_forget: function(p) {
			var n = state.saved.length;

			state.saved = state.saved.filter(function(s) { return s.ssid !== p.ssid; });

			if (state.saved.length === n)
				return fail('That network is not saved.');

			var u = uplink('trm_wwan');

			if (u.ssid === p.ssid) {
				u.up = u.online = false;
				u.ssid = '';
				u.detail = 'Choose a Wi-Fi network';
			}

			return ok();
		},

		wifi_saved: function() {
			return ok({ networks: clone(state.saved) });
		},

		set_ap: function(p) {
			if (p.ssid && p.ssid.length > 32)
				return fail('That name is too long.');

			if (p.key && (String(p.key).length < 8 || String(p.key).length > 63))
				return fail('The password must be 8 to 63 characters.');

			if (p.country && p.country !== 'auto' && !/^[A-Z]{2}$/.test(p.country))
				return fail('Unknown country.');

			return delay(700).then(function() {
				if (p.ssid)
					state.wifi.ssid = p.ssid;

				if (p.country === 'auto') {
					state.flags.autoCountry = true;
					state.wifi.country = state.wifi.country_detected || state.wifi.country;
				}
				else if (p.country) {
					state.flags.autoCountry = false;
					state.wifi.country = p.country;
				}

				return ok();
			});
		},

		set_channel: function(p) {
			var r = state.wifi.radios.filter(function(x) { return x.band === p.band; })[0];

			if (!r)
				return fail('No radio for that band.');

			/* rpcd only passes strings for this parameter */
			if (typeof(p.channel) !== 'string' || (p.channel !== 'auto' && !/^[0-9]+$/.test(p.channel)))
				return fail('Unknown channel.');

			if (r.locked)
				return fail("That band follows the Wi-Fi you're connected to, so its channel can't change right now.");

			return delay(500).then(function() {
				if (p.channel === 'auto') {
					r.auto = true;
					r.channel = 6;		/* read back from the radio: a number */
				}
				else {
					r.auto = false;
					r.channel = p.channel;	/* read back from the config: a string */
				}

				return ok();
			});
		},

		mac: function(p) {
			if (p.target !== 'wifi' && p.target !== 'ethernet')
				return fail('Choose Wi-Fi or Ethernet.');

			var mac = '';

			if (p.action === 'random')
				mac = macRandom();
			else if (p.action === 'reset')
				mac = '';
			else if (p.action === 'set') {
				if (!/^([0-9a-f]{2}:){5}[0-9a-f]{2}$/i.test(p.mac || ''))
					return fail("That isn't a MAC address.");

				mac = p.mac;
			}
			else
				return fail('Unknown action.');

			if (p.target === 'wifi' && !uplink('trm_wwan').up)
				return fail('Connect to a Wi-Fi network first.');

			return ok({ mac: mac });
		},

		device_block: function(p) {
			var d = state.devices.filter(function(x) { return x.mac === p.mac; })[0];

			if (!d)
				return fail('That device is not connected any more.');

			d.blocked = !!p.blocked;

			return ok();
		},

		device_rename: function(p) {
			var d = state.devices.filter(function(x) { return x.mac === p.mac; })[0];

			if (!d)
				return fail('That device is not connected any more.');

			var name = String(p.name || '').replace(/[ _]/g, '-').replace(/[^A-Za-z0-9-]/g, '').slice(0, 40);

			if (!name)
				return fail('Enter a name.');

			d.name = name;

			return ok();
		},

		tailscale_login: function() {
			if (state.tailscale.state === 'Running')
				return fail('Tailscale is already logged in.');

			return delay(2500).then(function() {
				state.tailscale.auth_url = 'https://login.tailscale.com/a/8f3c2e91d4b7';

				return ok({ auth_url: state.tailscale.auth_url });
			});
		},

		tailscale_logout: function() {
			state.tailscale.state = 'NeedsLogin';
			state.tailscale.auth_url = '';
			state.tailscale.exit_nodes = [];

			return ok();
		},

		wg_import: function(p) {
			var conf = String(p.conf || '');
			var label = String(p.label || 'VPN').replace(/[^A-Za-z0-9 ._-]/g, '').slice(0, 32);
			var key = /^\s*PrivateKey\s*=\s*(\S+)/mi.exec(conf);
			var pub = /^\s*PublicKey\s*=\s*(\S+)/mi.exec(conf);
			var b64 = /^[A-Za-z0-9+\/]{42,43}=$/;
			var endpoint = /^\s*Endpoint\s*=\s*(\S+)/mi.exec(conf);

			if (!conf)
				return fail('Paste the WireGuard file first.');

			if (!key || !b64.test(key[1]))
				return fail("That file doesn't look like a WireGuard profile (no private key).");

			if (!pub || !b64.test(pub[1]))
				return fail("That file doesn't look like a WireGuard profile (no peer key).");

			if (!/^\s*Address\s*=/mi.test(conf))
				return fail('The file has no Address line.');

			if (!endpoint)
				return fail('The file has no Endpoint line.');

			var n = 1;

			while (state.wireguard.some(function(x) { return x.name === 'wg_' + n; }))
				n++;

			state.wireguard.push({ name: 'wg_' + n, label: label, up: false, endpoint: endpoint[1], handshake: 0 });

			return ok({ name: 'wg_' + n });
		},

		wg_delete: function(p) {
			var n = state.wireguard.length;

			state.wireguard = state.wireguard.filter(function(x) { return x.name !== p.name; });

			if (state.wireguard.length === n)
				return fail('That profile does not exist.');

			if (state.mode.wg === p.name)
				state.mode.wg = '';

			return ok();
		},

		set_hide_router: function(p) {
			/* rpcd passes a real boolean; anything else is refused, like the plugin does */
			if (typeof(p.enabled) !== 'boolean')
				return fail('Send enabled as true or false.');

			state.hide_router = p.enabled;

			return ok();
		},

		uplink_order: function(p) {
			if (!Array.isArray(p.order))
				return fail('The order was not understood.');

			p.order.forEach(function(name, i) {
				var u = uplink(name);

				if (u)
					u.metric = (i + 1) * 10;
			});

			return ok();
		}
	};

	/* One ubus call. Resolves to the raw ubus result: [ code, data ] (4 = not found). */
	function call(object, method, params) {
		if (sim.unreachable)
			return delay(300).then(function() { throw new Error('Network error'); });

		calls.push({ time: Date.now(), method: method, params: clone(params || {}) });

		if (object !== 'travel' || !handlers[method])
			return Promise.resolve([ 4 ]);

		return delay(method === 'status' ? 60 : 120 + Math.random() * 200)
			.then(function() { return handlers[method](params || {}); })
			.then(function(data) { return [ 0, clone(data) ]; });
	}

	/* ---- what the preview page's buttons do ---- */

	var controls = {
		togglePortal: function() {
			var p = state.portal;

			if (p.state === 'detected') {
				state.portal = { state: 'none', host: '', url: '', since: 0 };
				state.flags.noInternet = false;
			}
			else
				state.portal = { state: 'detected', host: 'login.guestnet.example', url: 'http://login.guestnet.example/login', since: now() };

			recompute();

			return state.portal.state === 'detected';
		},

		flipSwitch: function() {
			var sw = state['switch'];

			sw.position = (sw.position === 'on') ? 'off' : 'on';
			state.mode.desired = sw[sw.position];
			recompute();

			return sw.position;
		},

		toggleUplinkWifi: function() {
			sim.uplinkWifi = !sim.uplinkWifi;
			recompute();

			return sim.uplinkWifi;
		},

		toggleTailscale: function() {
			var ts = state.tailscale;

			if (ts.state === 'Running') {
				ts.state = 'NeedsLogin';
				ts.auth_url = '';
				ts.exit_nodes = [];
			}
			else {
				ts.state = 'Running';
				ts.auth_url = '';
				ts.exit_nodes = clone(tsNodes);
			}

			recompute();

			return ts.state === 'Running';
		},

		/* What the router thinks the country is (from the access point it joined). '' means nothing detected. */
		setDetected: function(cc) {
			var w = state.wifi;

			w.country_detected = cc;
			w.country_source = cc ? 'nearby Wi-Fi' : '';

			/* with automatic country rules the radios follow what was detected */
			if (cc && state.flags.autoCountry)
				w.country = cc;

			return cc;
		},

		toggleUnreachable: function() {
			sim.unreachable = !sim.unreachable;

			return sim.unreachable;
		},

		reset: function() {
			state = fresh();
			sim.unreachable = false;
			sim.uplinkWifi = true;
			scanOverride = null;
			calls.length = 0;
		},

		state: function() {
			return {
				portal: state.portal.state === 'detected',
				position: state['switch'].position,
				uplinkWifi: sim.uplinkWifi,
				tailscale: state.tailscale.state === 'Running',
				detected: state.wifi.country_detected,
				unreachable: sim.unreachable
			};
		}
	};

	return {
		call: call,
		sim: controls,
		calls: calls,
		raw: function() { return state; },
		setScan: function(list) { scanOverride = list; }
	};
})();

window.TravelMock = TravelMock;

/* ------------------------------------------------------------------ *
 *  Boot: the same order LuCI uses. The view waits for luci-loaded.
 * ------------------------------------------------------------------ */

function fatal(err) {
	if (window.console)
		console.error(err);
}

L.require('view.travel.panel').then(function(instance) {
	window.__travelView = instance;
}).catch(fatal);

function boot() {
	L.loaded = true;
	Poll.start();
	document.dispatchEvent(new CustomEvent('luci-loaded'));
}

if (document.readyState === 'loading')
	document.addEventListener('DOMContentLoaded', boot);
else
	boot();
})();
