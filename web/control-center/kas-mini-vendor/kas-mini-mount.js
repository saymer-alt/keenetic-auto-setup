// KAS panel mount for kas-mini (Stage B1, issue saymer-alt/keenetic-auto-setup#425).
//
// Markup and event wiring are adapted from upstream kas-mini/index.html at the pinned
// SHA (PROVENANCE.json): element ids are prefixed km- and all lookups are scoped to the
// container, so they cannot collide with panel element ids; report classes are km-*
// for the same reason. The reviewed upstream behaviour is preserved verbatim: any input
// change invalidates the generated YAML (round-2 review), WG/AWG file reads are
// all-or-nothing with the reading-lock (round-3 review).
//
// B1 handoff boundary (bounded owner GO, review 5818028422): read-only UI experiment.
// The generated YAML is only downloadable — nothing in this mount calls any panel API,
// applies YAML, restarts services or touches the router. The import step is the
// EXISTING panel importer (file/paste + confirm + backup + rollback), performed
// manually by the operator; wiring the one-action handoff is Stage B3, not B1.
import { buildMiniMihomoConfig, createMiniUiState, readWgFileEntries } from './entry-kas-mini.js';

const CSS = `
.kas-mini-root p { margin: 6px 0; }
.kas-mini-root textarea { width: 100%; box-sizing: border-box; min-height: 110px; font-family: ui-monospace, monospace; }
.kas-mini-root #km-preview { min-height: 220px; }
.kas-mini-root .km-label { display: block; margin: 8px 0 2px; }
.kas-mini-root .km-opt { display: inline-flex; gap: 6px; align-items: center; margin: 4px 14px 4px 0; }
.kas-mini-root fieldset { border: 1px solid #8884; border-radius: 8px; margin: 10px 0; }
.kas-mini-root .km-btn { padding: 6px 14px; margin: 6px 6px 0 0; }
.kas-mini-root #km-report { margin-top: 10px; }
.kas-mini-root .km-err { color: #c0392b; }
.kas-mini-root .km-warn { color: #b8860b; }
.kas-mini-root .km-note { color: #666; font-size: 12px; }
.kas-mini-root .km-hidden { display: none; }
.kas-mini-root #km-subwrap.km-off { opacity: .5; }
`;

const MARKUP = `
<p class="km-note"><b>Эксперимент Phase 0 (issue #425, Stage B1).</b> Только локальная генерация нового ПОЛНОГО
<code>config.yaml</code> в браузере: без сети, без хранения ввода, без автоматического применения. Скачайте YAML и
примените его вручную через существующий импортёр панели выше (проверка / backup / rollback).<br>
EN: local generation only — download the YAML and import it manually via the existing panel importer above.
Nothing here applies config, restarts services or touches the router.</p>
<p class="km-label">Ссылки на серверы (по одной в строке: <code>vless://</code>, <code>hysteria2://</code>, <code>trojan://</code>, …)</p>
<textarea id="km-links" placeholder="vless://…&#10;hysteria2://…&#10;trojan://…" spellcheck="false"></textarea>
<label class="km-opt"><input type="checkbox" id="km-subsToggle"> 📡 Использовать URL-подписки (нативные proxy-providers, загрузит сам Mihomo после импорта)</label>
<div id="km-subwrap" class="km-off">
  <p class="km-label">URL-подписки (http(s), по одной в строке)</p>
  <textarea id="km-subUrls" placeholder="https://example.com/sub" spellcheck="false"></textarea>
</div>
<span class="km-opt"><button type="button" id="km-wgBtn" class="km-btn">📂 Добавить WireGuard / AmneziaWG (.conf, .wg, .awg)</button>
<span id="km-wgCount" class="km-note"></span></span>
<input type="file" id="km-wgFiles" multiple accept=".conf,.wg,.awg" class="km-hidden">
<div id="km-wgList" class="km-note"></div>
<p class="km-note">⚠️ Экспериментально, ограниченная поддержка: conf с <code>DNS =</code> или неизвестными полями отклоняется целиком (без молчаливой потери параметров). Полная поддержка WG DNS — отдельное решение после Phase 0.</p>
<p class="km-label">Настройки</p>
<fieldset>
  <label class="km-opt"><input type="checkbox" id="km-allowLan" checked> 🌐 Allow LAN (0.0.0.0)</label>
  <label class="km-opt"><input type="checkbox" id="km-mixedOn" checked> 🔌 Mixed Port</label>
  <input type="number" id="km-mixedPort" min="1" max="65535" value="7890" style="width:90px">
  <label class="km-opt"><input type="checkbox" id="km-webUI" checked> 🖥️ Web UI (MetaCubeXD, secret обязателен)</label>
  <label class="km-opt"><input type="checkbox" id="km-tun" checked> 🛡️ TUN Interface</label>
  <label class="km-opt"><input type="checkbox" id="km-mips" checked> ⚡ MIPS stack для TUN</label>
</fieldset>
<p class="km-note" id="km-mipsNote">⚡ MIPS stack требует Mihomo ≥ 1.19.31. MIPS — это имя TUN-стека Mihomo, а не архитектура CPU роутера.
Fallback gvisor — только явным отключением этого переключателя.</p>
<p class="km-note">🌐 bind-address «*» — все интерфейсы роутера; доступ извне ограничивается firewall (не меняется автоматически).
🖥️ Web UI эмитит <code>external-controller: 0.0.0.0:9090</code> со сгенерированным secret (без него API недоступен).
🔌 Mixed Port — комбинированный HTTP+SOCKS5 слушатель; при выключении переключателя слушателя в YAML нет; порт 9090 при включённом Web UI отклоняется (конфликт слушателей).
♻️ После изменения любых входных данных (ссылки, подписки, настройки, WG-файлы) созданный YAML удаляется, скачивание блокируется до следующего «Создать YAML» — устаревший конфиг скачать нельзя.
Выбор WG/AWG-файлов инвалидирует результат немедленно (до завершения чтения), на время чтения «Создать YAML» заблокирована; файлы добавляются только при успешном чтении всех выбранных.</p>
<button type="button" id="km-gen" class="km-btn">Создать YAML</button>
<button type="button" id="km-dl" class="km-btn" disabled>Скачать YAML</button>
<div id="km-report"></div>
<p class="km-label">Предпросмотр (read-only)</p>
<textarea id="km-preview" readonly spellcheck="false"></textarea>
`;

// Mount the read-only generator UI into `root` (the panel container #kas-mini-root).
// Idempotent: a second call on the same container is ignored (dataset guard mirrors
// the auto-mount guard in vendor-entry.js).
export function mountKasMini(root) {
    if (!root || root.dataset.kasMiniMounted) return null;
    root.dataset.kasMiniMounted = '1';

    const style = document.createElement('style');
    style.textContent = CSS;
    root.innerHTML = '';
    root.appendChild(style);
    const body = document.createElement('div');
    body.className = 'kas-mini-root';
    body.innerHTML = MARKUP;
    root.appendChild(body);

    const $ = id => root.querySelector('#' + id);
    const files = []; // {name, text} — только в памяти вкладки

    // Центральная инвалидация результата (upstream round-2 review #5817699546): любое
    // изменение входных данных делает сгенерированный YAML недействительным —
    // предпросмотр очищается, скачивание блокируется до следующего «Создать YAML».
    const ui = createMiniUiState();
    const STALE_NOTE = '⚠️ Входные данные изменились — созданный YAML удалён, скачивание заблокировано. Нажмите «Создать YAML», чтобы получить актуальный конфиг.';
    function invalidateGeneratedYaml() {
        if (ui.stale) return; // нечего инвалидировать — не затираем другие сообщения
        ui.invalidate();
        $('km-preview').value = '';
        $('km-dl').disabled = true;
        $('km-report').innerHTML = `<p class="km-warn">${STALE_NOTE}</p>`;
    }
    // Ссылки, подписки и порт — посимвольный ввод; переключатели и WG-файлы — change.
    for (const id of ['km-links', 'km-subUrls', 'km-mixedPort']) $(id).addEventListener('input', invalidateGeneratedYaml);
    for (const id of ['km-subsToggle', 'km-allowLan', 'km-mixedOn', 'km-webUI', 'km-tun', 'km-mips']) $(id).addEventListener('change', invalidateGeneratedYaml);

    $('km-wgBtn').addEventListener('click', () => $('km-wgFiles').click());
    let readingWg = false; // выбранные файлы ещё читаются → Generate заблокирован (upstream round-3 review #5817777839)
    $('km-wgFiles').addEventListener('change', async (ev) => {
        if (readingWg) { // повторный выбор во время чтения отклоняется целиком, без перемешивания
            ev.target.value = '';
            $('km-report').innerHTML = '<p class="km-warn">⏳ Предыдущее чтение WG/AWG-файлов ещё идёт — выберите файлы после его завершения.</p>';
            return;
        }
        invalidateGeneratedYaml(); // синхронно, ДО первого await — старый YAML исчезает сразу при выборе файлов
        const picked = Array.from(ev.target.files || []);
        ev.target.value = '';
        if (!picked.length) { renderWg(); return; }
        readingWg = true;
        $('km-gen').disabled = true; // генерация по неполным входным данным запрещена, пока файлы не прочитаны
        $('km-report').innerHTML = '<p class="km-note">⏳ Чтение выбранных WG/AWG-файлов…</p>';
        try {
            const entries = await readWgFileEntries(picked); // all-or-nothing: частичного «успеха» нет
            files.push(...entries);
            renderWg();
            $('km-report').innerHTML = `<p class="km-warn">${STALE_NOTE}</p><p class="km-note">📂 Файлы прочитаны (всего: ${files.length}) — нажмите «Создать YAML».</p>`;
        } catch (e) {
            renderWg(); // files не изменился — упавшие файлы не добавлены
            $('km-report').innerHTML = `<p class="km-err">❌ Не удалось прочитать WG/AWG-файл: ${escapeHtml(String(e && e.message || e))}. Файлы не добавлены — выберите их заново.</p><p class="km-warn">${STALE_NOTE}</p>`;
        } finally {
            readingWg = false;
            $('km-gen').disabled = false;
        }
    });
    function renderWg() {
        $('km-wgCount').textContent = files.length ? `файлов: ${files.length}` : '';
        $('km-wgList').textContent = files.map(f => f.name).join(', ');
    }
    $('km-subsToggle').addEventListener('change', () => {
        $('km-subwrap').classList.toggle('km-off', !$('km-subsToggle').checked);
    });
    $('km-tun').addEventListener('change', () => {
        const on = $('km-tun').checked;
        $('km-mips').disabled = !on;
        $('km-mipsNote').classList.toggle('km-hidden', !on);
    });
    $('km-mixedOn').addEventListener('change', () => {
        $('km-mixedPort').disabled = !$('km-mixedOn').checked;
    });

    $('km-gen').addEventListener('click', () => {
        if (readingWg) return; // защита от гонки: файлы ещё читаются — входные данные неполны
        $('km-report').innerHTML = '';
        try {
            const r = buildMiniMihomoConfig({
                linksText: $('km-links').value,
                subscriptionUrlsText: $('km-subUrls').value,
                subscriptions: $('km-subsToggle').checked,
                wgFiles: files,
                allowLan: $('km-allowLan').checked,
                mixedOn: $('km-mixedOn').checked,
                mixedPort: $('km-mixedOn').checked ? ($('km-mixedPort').value === '' ? 7890 : Number($('km-mixedPort').value)) : null,
                webUI: $('km-webUI').checked,
                tun: $('km-tun').checked,
                mipsStack: $('km-mips').checked,
            });
            ui.onGenerated(r.yaml);
            $('km-preview').value = r.yaml;
            $('km-dl').disabled = false;
            const rep = r.report;
            const parts = [];
            parts.push(`✅ узлов: ${rep.nodes}, провайдеров: ${rep.subscriptions.providers.length || 0}`);
            if (!rep.settings.mixedEnabled) parts.push('🔌 Mixed Port выключен — HTTP/SOCKS-слушателя в YAML нет');
            if (rep.links.accepted) parts.push(`ссылок принято: ${rep.links.accepted}`);
            if (rep.links.rejected) parts.push(`<span class="km-err">строк отклонено: ${rep.links.rejected}</span>`);
            if (rep.wg.accepted) parts.push(`WG/AWG принято: ${rep.wg.accepted}`);
            if (rep.wg.refused) parts.push(`<span class="km-err">WG/AWG отклонено: ${rep.wg.refused}</span>`);
            $('km-report').innerHTML = '<p>' + parts.join(' · ') + '</p>';
            const ul = [];
            for (const e of rep.links.errors) ul.push(`<li class="km-err">${escapeHtml(e.line)} — ${escapeHtml(e.message)}</li>`);
            for (const f of rep.wg.files) {
                if (f.status !== 'accepted') ul.push(`<li class="km-err">${escapeHtml(f.name)}: ${escapeHtml(f.error.message)}</li>`);
                else for (const w of (f.warnings || [])) ul.push(`<li class="km-warn">${escapeHtml(f.name)}: ${escapeHtml(w.key)} — ${escapeHtml(w.detail)}</li>`);
            }
            for (const w of rep.warnings) ul.push(`<li class="km-warn">${escapeHtml(w)}</li>`);
            for (const n of rep.notes) ul.push(`<li class="km-note">${escapeHtml(n)}</li>`);
            if (rep.settings.webUI.enabled) ul.push('<li>secret контроллера сгенерирован и включён в YAML (строка <code>secret:</code> в предпросмотре)</li>');
            $('km-report').insertAdjacentHTML('beforeend', '<ul>' + ul.join('') + '</ul>');
        } catch (e) {
            ui.onGenerateError(); // старый YAML не переживает неудачную генерацию
            $('km-preview').value = '';
            $('km-dl').disabled = true;
            $('km-report').innerHTML = `<p class="km-err">❌ ${escapeHtml(String(e && e.message || e))}</p>`;
        }
    });
    $('km-dl').addEventListener('click', () => {
        if (!ui.canDownload()) return;
        const blob = new Blob([ui.yaml], { type: 'text/yaml' });
        const a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = 'config.yaml';
        a.click();
        URL.revokeObjectURL(a.href);
    });

    return { root, ui };
}

function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
