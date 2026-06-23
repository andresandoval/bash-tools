/* Meeting Notes — search + browse UI. No framework; reads window.NOTES_INDEX. */
(function () {
	"use strict";

	var NOTES = (window.NOTES_INDEX || []).slice();
	var sidebar = document.getElementById("sidebar");
	var main = document.getElementById("main");
	var search = document.getElementById("search");

	function escapeHtml(s) {
		return s.replace(/[&<>"']/g, function (c) {
			return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
		});
	}

	function renderMarkdown(md) {
		if (window.marked && typeof window.marked.parse === "function") {
			return window.marked.parse(md);
		}
		// Minimal fallback if the vendored renderer is missing.
		return "<pre>" + escapeHtml(md) + "</pre>";
	}

	/* ---- Sidebar: project -> meetings tree ---- */
	function buildTree() {
		var projects = {};
		NOTES.forEach(function (n) {
			(projects[n.project] = projects[n.project] || {})[n.meeting] =
				(projects[n.project][n.meeting] || 0) + 1;
		});

		sidebar.innerHTML = "";
		Object.keys(projects).sort().forEach(function (proj) {
			var meetings = projects[proj];
			var total = Object.keys(meetings).reduce(function (a, m) { return a + meetings[m]; }, 0);

			var wrap = document.createElement("div");
			wrap.className = "proj open";

			var head = document.createElement("div");
			head.className = "proj-head";
			head.innerHTML = '<span><span class="caret">▶</span> ' + escapeHtml(proj) +
				'</span><span class="count">' + total + "</span>";
			head.onclick = function () { wrap.classList.toggle("open"); };
			wrap.appendChild(head);

			var list = document.createElement("div");
			list.className = "meetings";
			Object.keys(meetings).sort().forEach(function (m) {
				var row = document.createElement("div");
				row.className = "meeting";
				row.innerHTML = "<span>" + escapeHtml(m) + '</span><span class="count">' +
					meetings[m] + "</span>";
				row.onclick = function () {
					search.value = "";
					setActive(row);
					showList(NOTES.filter(function (n) {
						return n.project === proj && n.meeting === m;
					}), "", proj + " / " + m);
				};
				list.appendChild(row);
			});
			wrap.appendChild(list);
			sidebar.appendChild(wrap);
		});
	}

	function setActive(row) {
		var prev = sidebar.querySelector(".meeting.active");
		if (prev) prev.classList.remove("active");
		if (row) row.classList.add("active");
	}

	/* ---- List / results view ---- */
	function snippet(content, query) {
		var text = content.replace(/\s+/g, " ").trim();
		if (!query) return escapeHtml(text.slice(0, 160)) + (text.length > 160 ? "…" : "");
		var i = text.toLowerCase().indexOf(query.toLowerCase());
		if (i === -1) return escapeHtml(text.slice(0, 160)) + (text.length > 160 ? "…" : "");
		var start = Math.max(0, i - 50);
		var slice = text.slice(start, i + query.length + 90);
		var html = escapeHtml(slice);
		var re = new RegExp(query.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "ig");
		html = html.replace(re, function (m) { return "<mark>" + m + "</mark>"; });
		return (start > 0 ? "…" : "") + html + "…";
	}

	function showList(notes, query, heading) {
		setActive(null);
		if (!notes.length) {
			main.innerHTML = '<p class="empty">No notes found' +
				(query ? " for “" + escapeHtml(query) + "”." : ".") + "</p>";
			return;
		}
		var head = heading
			? escapeHtml(heading) + " — " + notes.length + " note(s)"
			: notes.length + " note(s)" + (query ? " matching “" + escapeHtml(query) + "”" : "");
		var html = '<p class="list-head">' + head + "</p>";
		notes.forEach(function (n) {
			var idx = NOTES.indexOf(n);
			html += '<div class="card" data-i="' + idx + '">' +
				'<div class="meta"><span class="title">' + escapeHtml(n.title) +
				'</span><span class="date">' + escapeHtml(n.date) + "</span></div>" +
				'<div class="snippet">' + snippet(n.content, query) + "</div></div>";
		});
		main.innerHTML = html;
		Array.prototype.forEach.call(main.querySelectorAll(".card"), function (card) {
			card.onclick = function () { showNote(NOTES[+card.getAttribute("data-i")]); };
		});
	}

	/* ---- Single note view ---- */
	function showNote(n) {
		main.innerHTML =
			'<div class="note-bar"><button class="back">← Back</button>' +
			'<span class="where">' + escapeHtml(n.title) + " · " + escapeHtml(n.date) + "</span></div>" +
			'<article class="note">' + renderMarkdown(n.content) + "</article>";
		main.querySelector(".back").onclick = function () { runSearch(); };
		window.scrollTo(0, 0);
	}

	/* ---- Search ---- */
	function runSearch() {
		var q = search.value.trim();
		if (!q) { showList(NOTES, "", null); return; }
		var lower = q.toLowerCase();
		var hits = NOTES.filter(function (n) {
			return (n.content + " " + n.title + " " + n.date).toLowerCase().indexOf(lower) !== -1;
		});
		showList(hits, q, null);
	}

	/* ---- Init ---- */
	if (!NOTES.length) {
		main.innerHTML = '<p class="empty">No notes yet. Add one with <code>./add_notes.sh</code>.</p>';
	} else {
		buildTree();
		showList(NOTES, "", null);
	}
	search.addEventListener("input", runSearch);
})();
