/* Meeting Notes — search + browse UI. No framework; reads window.NOTES_INDEX.
   Each record: { segments: [..folders], name, date, path, content }. */
(function () {
	"use strict";

	var NOTES = (window.NOTES_INDEX || []).slice();
	var sidebar = document.getElementById("sidebar");
	var main = document.getElementById("main");
	var search = document.getElementById("search");

	function escapeHtml(s) {
		return String(s).replace(/[&<>"']/g, function (c) {
			return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
		});
	}

	function renderMarkdown(md) {
		if (window.marked && typeof window.marked.parse === "function") {
			return window.marked.parse(md);
		}
		return "<pre>" + escapeHtml(md) + "</pre>";
	}

	function noteLabel(n) { return n.date || n.name; }
	function notePath(n) { return n.segments.join(" / "); }

	/* ---- Build an N-level tree from note segments ---- */
	function buildTree(notes) {
		var root = { children: {}, notes: [] };
		notes.forEach(function (n) {
			var node = root;
			n.segments.forEach(function (seg) {
				node.children[seg] = node.children[seg] || { children: {}, notes: [] };
				node = node.children[seg];
			});
			node.notes.push(n);
		});
		return root;
	}

	function subtreeCount(node) {
		var total = node.notes.length;
		Object.keys(node.children).forEach(function (k) {
			total += subtreeCount(node.children[k]);
		});
		return total;
	}

	function byDateDesc(a, b) {
		var d = (b.date || "").localeCompare(a.date || "");
		return d !== 0 ? d : (b.name || "").localeCompare(a.name || "");
	}

	/* ---- Sidebar tree (recursive) ---- */
	function renderNode(name, node, depth, prefixSegs) {
		var wrap = document.createElement("div");
		wrap.className = "folder open";

		var head = document.createElement("div");
		head.className = "folder-head";
		head.style.paddingLeft = 10 + depth * 14 + "px";
		head.innerHTML = '<span class="caret">▶</span><span class="label">' +
			escapeHtml(name) + '</span><span class="count">' + subtreeCount(node) + "</span>";
		var here = prefixSegs.concat([name]);
		head.onclick = function (e) {
			if (e.detail === 2) { // double-click: filter to this folder's notes
				search.value = "";
				showList(notesUnder(node), "", here.join(" / "));
				return;
			}
			wrap.classList.toggle("open");
		};
		wrap.appendChild(head);

		var body = document.createElement("div");
		body.className = "folder-body";

		Object.keys(node.children).sort().forEach(function (k) {
			body.appendChild(renderNode(k, node.children[k], depth + 1, here));
		});

		node.notes.slice().sort(byDateDesc).forEach(function (n) {
			var leaf = document.createElement("div");
			leaf.className = "note-leaf";
			leaf.style.paddingLeft = 10 + (depth + 1) * 14 + "px";
			leaf.innerHTML = '<span class="dot">•</span><span class="label">' +
				escapeHtml(noteLabel(n)) + "</span>";
			leaf.onclick = function () { setActive(leaf); showNote(n); };
			body.appendChild(leaf);
		});

		wrap.appendChild(body);
		return wrap;
	}

	function notesUnder(node) {
		var out = node.notes.slice();
		Object.keys(node.children).forEach(function (k) {
			out = out.concat(notesUnder(node.children[k]));
		});
		return out;
	}

	function renderSidebar() {
		var root = buildTree(NOTES);
		sidebar.innerHTML = "";
		Object.keys(root.children).sort().forEach(function (k) {
			sidebar.appendChild(renderNode(k, root.children[k], 0, []));
		});
		// Notes that live at the repo root (no folders), if any.
		root.notes.slice().sort(byDateDesc).forEach(function (n) {
			var leaf = document.createElement("div");
			leaf.className = "note-leaf";
			leaf.style.paddingLeft = "10px";
			leaf.innerHTML = '<span class="dot">•</span><span class="label">' +
				escapeHtml(noteLabel(n)) + "</span>";
			leaf.onclick = function () { setActive(leaf); showNote(n); };
			sidebar.appendChild(leaf);
		});
	}

	function setActive(row) {
		var prev = sidebar.querySelector(".note-leaf.active");
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
				'<div class="meta"><span class="title">' + escapeHtml(notePath(n) || n.name) +
				'</span><span class="date">' + escapeHtml(noteLabel(n)) + "</span></div>" +
				'<div class="snippet">' + snippet(n.content, query) + "</div></div>";
		});
		main.innerHTML = html;
		Array.prototype.forEach.call(main.querySelectorAll(".card"), function (card) {
			card.onclick = function () { showNote(NOTES[+card.getAttribute("data-i")]); };
		});
	}

	/* ---- Single note view ---- */
	function showNote(n) {
		var where = (notePath(n) ? notePath(n) + " · " : "") + noteLabel(n);
		main.innerHTML =
			'<div class="note-bar"><button class="back">← Back</button>' +
			'<span class="where">' + escapeHtml(where) + "</span></div>" +
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
			return (n.content + " " + notePath(n) + " " + n.name + " " + n.date)
				.toLowerCase().indexOf(lower) !== -1;
		});
		showList(hits, q, null);
	}

	/* ---- Init ---- */
	if (!NOTES.length) {
		main.innerHTML = '<p class="empty">No notes yet. Add one with <code>add-notes &lt;path&gt;</code>.</p>';
	} else {
		renderSidebar();
		showList(NOTES, "", null);
	}
	search.addEventListener("input", runSearch);
})();
