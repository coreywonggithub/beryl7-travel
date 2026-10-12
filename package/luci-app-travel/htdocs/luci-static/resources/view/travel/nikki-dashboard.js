'use strict';
'require view';
'require rpc';
'require uci';

/*
 * nikki's web dashboard (MetaCubeXD) inside LuCI, already connected (Corey, 2026-10-08): a tab under
 * Services, Nikki, so the router's own login is the only one.
 *
 * It builds the same link nikki's "Open Dashboard" button builds: the address and key come from the
 * running engine (luci.nikki profile), or, if nikki ever renames that call, from nikki's saved settings.
 * Nothing here knows MetaCubeXD, mihomo or nikki beyond that link, so all three keep updating on their
 * own (nikki's "Update Dashboard" button, its package) without this file changing.
 *
 * The router serves LuCI over plain http; a dashboard on http inside an https page would be blocked.
 */

const callRCList = rpc.declare({ object: 'rc', method: 'list', params: ['name'], expect: { '': {} } });
const callNikkiProfile = rpc.declare({
	object: 'luci.nikki', method: 'profile', params: ['defaults'], expect: { '': {} }
});

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(callRCList('nikki'), {}),
			L.resolveDefault(callNikkiProfile({
				'external-ui-name': null, 'external-controller': null,
				'external-controller-tls': null, 'secret': null
			}), null),
			L.resolveDefault(uci.load('nikki'), null)
		]);
	},

	render: function(data) {
		const running = !!(data[0] && data[0].nikki && data[0].nikki.running);
		const p = data[1] || {};
		const listen = p['external-controller'] || uci.get('nikki', 'mixin', 'api_listen') || '';
		const tls = p['external-controller-tls'] || '';
		const secret = (p['secret'] != null ? p['secret'] : uci.get('nikki', 'mixin', 'api_secret')) || '';
		const uiName = p['external-ui-name'] || '';
		const note = function(text) {
			return E('div', { 'class': 'cbi-section' }, [ E('p', {}, text) ]);
		};

		if (!running)
			return note(_('nikki is switched off, so its dashboard is not running. It starts when the Travel panel\'s way out is set to nikki (China mode).'));

		const bind = tls || listen;
		if (!bind)
			return note(_('nikki has no dashboard address configured (Mixin Config, API).'));

		const port = bind.substring(bind.lastIndexOf(':') + 1);
		const host = window.location.hostname;	/* IPv6 hosts come with their brackets */
		const query = new URLSearchParams({ host: host, hostname: host, port: port, secret: secret }).toString();
		/* zashboard reads the address and key from the query, MetaCubeXD (a hash-routed app) only from the
		 * query after "#/" (its autoLogin(route.query)), so both carry them; nikki's own button sets only the
		 * first, which is why it did not connect MetaCubeXD (2026-10-08) */
		const url = (tls ? 'https' : 'http') + '://' + host + ':' + port + '/ui/' + (uiName ? uiName + '/' : '') +
			'?' + query + '#/?' + query;

		return E('div', {}, [
			E('iframe', {
				'src': url,
				'title': _('nikki dashboard'),
				'style': 'width:100%;height:calc(100vh - 180px);min-height:560px;border:0;border-radius:8px;display:block'
			}),
			E('p', { 'class': 'cbi-section-descr', 'style': 'margin-top:8px' }, [
				_('nikki\'s own dashboard (MetaCubeXD). '),
				E('a', { 'href': url, 'target': '_blank', 'rel': 'noopener noreferrer' }, _('Open it in a new tab'))
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
