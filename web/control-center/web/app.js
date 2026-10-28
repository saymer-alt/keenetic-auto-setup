'use strict';
const words={
 ru:{
  scope:'Экспериментальная версия: только локальный доступ. Перед работой с роутером требуется проверка безопасности.',status:'Состояние',unknown:'Состояние сети не проверено',binary:'Файлы: Mihomo {m}; MagiTrickle {mt}. Наличие файла не означает работающий сервис.',present:'есть',absent:'не найден',refresh:'Обновить сведения',
  config:'Конфигурация Mihomo',configHelp:'Загрузите полный готовый config.yaml либо вставьте YAML. Импорт выполняет штатный KAS. Подписки и ключи не сохраняются в браузере.',fileLabel:'Файл YAML (если выбран, он имеет приоритет):',pasteLabel:'Или вставьте полный YAML:',warning:'Внимание: применение может временно остановить Mihomo. Предыдущая конфигурация сохраняется и откатывается штатным импортером при предусмотренных им ошибках. Во время операции не перезагружайте роутер.',apply:'Применить YAML',confirm:'Заменить текущий config.yaml? Mihomo может быть временно перезапущен.',applying:'Импорт выполняется. Не выключайте роутер…',importOk:'Импортер завершён успешно. Код выхода: {exit}',importFail:'Импортер сообщил об ошибке. Код выхода: {exit}. Подробности и фактическое состояние проверьте через Doctor/SSH. {code}',importNone:'Импорт ещё не выполнялся.',importError:'Не удалось выполнить запрос импорта: {code}',fileTooLarge:'YAML слишком большой (лимит 1 МиБ).',emptyFile:'Выберите YAML или вставьте его содержимое.',
  providers:'Список серверов подписки',providersHelp:'Если администратор включил экспорт, можно скачать совместимый с Mihomo Unified Generator JSON: только имена узлов и провайдеров, без паролей и адресов. Затем в генераторе выберите «Импорт узлов из работающего Mihomo» → «Загрузить .json». Сам Mihomo не изменяется.',providersDownload:'Скачать JSON имён узлов',providersDisabled:'Экспорт не включён администратором',providersWorking:'Получаем список из работающего Mihomo…',providersSuccess:'Файл имён узлов сохранён. Загрузите его в Mihomo Builder и выберите исключения.',providersError:'Не удалось получить имена: {code}. Проверьте доступность локального API Mihomo и его secret.',
  filterHeading:'🚫 Фильтрация серверов подписки (предпросмотр)',filterHelp:'Эксперимент: показывает загруженные Mihomo имена и будущие изменения exclude-filter. Эта версия ничего не применяет. Редактируем только совместимые HTTP-провайдеры; сложный YAML требует обычного импорта.',filterLoad:'Загрузить провайдеры и узлы',filterProviderLabel:'Провайдер:',filterPreview:'Показать фильтр для отмеченных',filterClear:'Показать удаление фильтра',filterHint:'Галочка означает исключить узел. Из ответа Mihomo уже исключённые узлы могут отсутствовать. Перед заменой существующего фильтра проверьте его содержание.',filterNoProvider:'Поддерживаемых HTTP-провайдеров нет',filterExisting:'Существующий exclude-filter: {filter}',filterNoFilter:'не задан',filterLoading:'Читаем локальные данные…',filterLoaded:'Провайдеры загружены. Выберите исключения.',filterCannotLoad:'Не удалось прочитать данные: {code}',filterNoNames:'Доступных узлов нет (либо они уже скрыты действующим фильтром).',filterTooMany:'Показаны первые {count} узлов; полный список доступен в JSON-экспорте.',filterPreviewing:'Проверяем изменения…',filterPreviewReady:'Предпросмотр готов. Никакие изменения не применены.',filterPreviewError:'Ошибка предпросмотра: {code}',filterNothing:'Выберите хотя бы один узел.',filterProposed:'Было: {before}\nБудет: {after}\nТолько предпросмотр — не применено.',
  doctor:'Диагностика Doctor',help:'Запуск штатного Doctor по запросу. Результат не означает, что маршрутизация каждого клиента проверена.',run:'Запустить Doctor',copy:'Копировать отчёт',details:'Реальный вывод команды',running:'Doctor выполняется…',finished:'Команда завершена; код выхода: {exit}',failed:'Команда не завершилась успешно; код выхода: {exit}; ошибка: {code}',error:'Не удалось выполнить запрос: {code}',footer:'При сбое импорта не заявляйте об откате без фактической проверки. Перед отправкой диагностического отчёта проверьте его вручную.',timestamp:'Время: {time}',notrun:'Doctor ещё не запускался.'
 },
 en:{
  scope:'Experimental loopback-only prototype. Security review is required before router deployment.',status:'Status',unknown:'Network health has not been tested',binary:'Files: Mihomo {m}; MagiTrickle {mt}. Presence does not prove service health.',present:'found',absent:'not found',refresh:'Refresh evidence',
  config:'Mihomo configuration',configHelp:'Upload a complete config.yaml or paste YAML. The canonical KAS importer does the work. Browser storage does not retain your secrets.',fileLabel:'YAML file (takes precedence if selected):',pasteLabel:'Or paste complete YAML:',warning:'Warning: applying may temporarily stop Mihomo. The canonical importer maintains previous-config backup and rollback for the failures it handles. Do not reboot the router mid-operation.',apply:'Apply YAML',confirm:'Replace current config.yaml? Mihomo might restart temporarily.',applying:'Import is running. Do not power off the router…',importOk:'Importer finished successfully. Exit code: {exit}',importFail:'Importer failed. Exit code: {exit}. Check the actual state with Doctor/SSH. {code}',importNone:'No import has been started.',importError:'Import request failed: {code}',fileTooLarge:'YAML exceeds 1 MiB.',emptyFile:'Select a YAML file or paste its contents.',
  providers:'Subscription server names',providersHelp:'If the administrator enabled export, download a JSON compatible with Mihomo Unified Generator: provider and node names only, no server addresses or passwords. In the builder use “Import nodes from running Mihomo” → “Upload .json”. This does not change Mihomo.',providersDownload:'Download node names JSON',providersDisabled:'Export is not enabled by the administrator',providersWorking:'Reading active Mihomo providers…',providersSuccess:'Names JSON saved. Upload it to Mihomo Builder and choose exclusions.',providersError:'Unable to read names: {code}. Check the local Mihomo API and its secret.',
  filterHeading:'🚫 Subscription server filtering (preview)',filterHelp:'Experimental read-only preview of loaded Mihomo node names and possible exclude-filter changes. This version does not apply changes. Only supported HTTP providers can be edited; complex YAML must use the ordinary importer.',filterLoad:'Load providers and nodes',filterProviderLabel:'Provider:',filterPreview:'Preview filter for checked nodes',filterClear:'Preview removing filter',filterHint:'Checked means exclude. Previously excluded nodes may be absent from Mihomo API. Review an existing filter before replacing it.',filterNoProvider:'No supported HTTP providers',filterExisting:'Existing exclude-filter: {filter}',filterNoFilter:'not set',filterLoading:'Reading local data…',filterLoaded:'Providers loaded. Select exclusions.',filterCannotLoad:'Cannot read data: {code}',filterNoNames:'No visible nodes (or already hidden by the active filter).',filterTooMany:'Showing first {count} nodes; full list is available via JSON export.',filterPreviewing:'Validating preview…',filterPreviewReady:'Preview ready. No changes have been applied.',filterPreviewError:'Preview error: {code}',filterNothing:'Select at least one node.',filterProposed:'Previous: {before}\nProposed: {after}\nPreview only — not applied.',
  doctor:'Doctor diagnostics',help:'Run the canonical Doctor on demand. This does not prove every client route.',run:'Run Doctor',copy:'Copy report',details:'Original command output',running:'Doctor is running…',finished:'Command finished; exit code: {exit}',failed:'Command did not complete successfully; exit code: {exit}; error: {code}',error:'Request failed: {code}',footer:'Do not claim rollback without checking the actual router state. Review diagnostics manually before sharing.',timestamp:'Time: {time}',notrun:'Doctor has not been run yet.'
 }
};
let lang=(navigator.language||'en').toLowerCase().startsWith('ru')?'ru':'en';
try{const s=localStorage.getItem('kas_lang');if(s==='ru'||s==='en')lang=s;}catch(_){}
let statusData=null,doctorData=null,busy=false,importData=null,submitting=false,pollTimer=null,importMessage='';
let exporting=false,providerMessage='';
let filterInspect=null,filterNodes=null,filterStatus='',filterSelectedProvider='',filterLoading=false,filterBusy=false;
const el=id=>document.getElementById(id);
const t=(key,params={})=>{
 const value=words[lang][key]??words.en[key]??key;
 return value.replace(/\{(\w+)\}/g,(_,k)=>String(params[k]??''));
};
const set=(id,value)=>{el(id).textContent=value;};
function draw(){
 document.documentElement.lang=lang;
 for(const [id,key] of [['scope','scope'],['status-heading','status'],['refresh','refresh'],['config-heading','config'],['config-help','configHelp'],['file-label','fileLabel'],['paste-label','pasteLabel'],['config-warning','warning'],['apply','apply'],['filter-heading','filterHeading'],['filter-help','filterHelp'],['filter-load','filterLoad'],['filter-provider-label','filterProviderLabel'],['filter-preview','filterPreview'],['filter-clear','filterClear'],['filter-hint','filterHint'],['providers-heading','providers'],['providers-help','providersHelp'],['providers-download','providersDownload'],['doctor-heading','doctor'],['doctor-help','help'],['run','run'],['copy','copy'],['details-label','details'],['footer','footer']])set(id,t(key));
 set('status-text',statusData?t('unknown')+' — '+t('timestamp',{time:statusData.timestamp}):t('unknown'));
 set('binary-text',statusData?t('binary',{m:t(statusData.mihomo_binary?'present':'absent'),mt:t(statusData.magitrickle_binary?'present':'absent')}):'');
 const runningImport=importData?.state==='RUNNING';
 let message=t('importNone');
 if(importData){
  if(runningImport)message=t('applying');
  else if(importData.state==='OK')message=t('importOk',{exit:importData.exit_code});
  else if(importData.state==='FAIL'||importData.error_code&&importData.error_code!=='NO_OPERATION')message=t('importFail',{exit:importData.exit_code??'?',code:importData.error_code??'UNKNOWN'});
 }
 if(importMessage)message=importMessage;
 set('config-state',message);
 el('apply').disabled=submitting||runningImport;
 set('filter-state',filterLoading?t('filterLoading'):filterStatus);
 el('filter-load').disabled=filterLoading||filterBusy;
 el('filter-preview').disabled=!filterInspect||filterBusy||filterLoading||!filterSelectedProvider;
 el('filter-clear').disabled=!filterInspect||filterBusy||filterLoading||!filterSelectedProvider;
 set('providers-state',exporting?t('providersWorking'):providerMessage);
 el('providers-download').disabled=exporting;
 set('doctor-state',busy?t('running'):doctorData?((doctorData.error_code||doctorData.exit_code!==0)?t('failed',{exit:doctorData.exit_code??'?',code:doctorData.error_code??'EXIT_NONZERO'}):t('finished',{exit:doctorData.exit_code}))+ ' — '+t('timestamp',{time:doctorData.timestamp}):t('notrun'));
 set('output',doctorData?.details||'');
 el('copy').disabled=!doctorData||!doctorData.details;el('run').disabled=busy||runningImport;
 el('ru').setAttribute('aria-pressed',String(lang==='ru'));el('en').setAttribute('aria-pressed',String(lang==='en'));
}
async function refresh(){
 try{const resp=await fetch('/api/status',{cache:'no-store'});if(!resp.ok)throw Error('HTTP '+resp.status);statusData=await resp.json();}
 catch(e){statusData=null;set('status-text',t('error',{code:String(e)}));return;}
 draw();
}
async function runDoctor(){
 if(busy||importData?.state==='RUNNING')return;busy=true;draw();
 try{const resp=await fetch('/api/doctor',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}',cache:'no-store'});
  doctorData=await resp.json();if(!resp.ok&&!doctorData.error_code)doctorData.error_code='HTTP_'+resp.status;}
 catch(e){doctorData={error_code:String(e),timestamp:new Date().toISOString(),details:''};}
 finally{busy=false;draw();}
}
function schedulePoll(){
 if(pollTimer!==null)return;
 pollTimer=setTimeout(()=>{pollTimer=null;refreshImport();},1500);
}
async function refreshImport(){
 try{
  const resp=await fetch('/api/config/operation',{cache:'no-store'});
  if(!resp.ok)throw Error('HTTP '+resp.status);
  importData=await resp.json();
  importMessage='';
 }catch(e){importMessage=t('importError',{code:String(e)});}
 finally{draw();if(importData?.state==='RUNNING')schedulePoll();}
}
async function applyYAML(){
 if(submitting||importData?.state==='RUNNING')return;
 const file=el('config-file').files[0];
 const pasted=el('yaml-paste').value;
 if(!file&&!pasted){importMessage=t('emptyFile');draw();return;}
 const limit=1024*1024;
 let bytes;
 if(file){
  if(file.size>limit){importMessage=t('fileTooLarge');draw();return;}
  bytes=new Uint8Array(await file.arrayBuffer());
 }else{bytes=new TextEncoder().encode(pasted);}
 if(bytes.length===0){importMessage=t('emptyFile');draw();return;}
 if(bytes.length>limit){importMessage=t('fileTooLarge');draw();return;}
 if(!window.confirm(t('confirm')))return;
 submitting=true;importMessage='';draw();
 try{
  const resp=await fetch('/api/config/import',{method:'POST',headers:{'Content-Type':'application/x-yaml','X-KAS-Confirm':'apply'},body:bytes,cache:'no-store'});
  importData=await resp.json();
  if(resp.status!==202){importMessage=t('importError',{code:importData?.error_code??'HTTP_'+resp.status});}
  else{
   el('config-file').value='';el('yaml-paste').value='';
   schedulePoll();
  }
 }catch(e){importMessage=t('importError',{code:String(e)});}
 finally{submitting=false;draw();}
}
for(const l of ['ru','en'])el(l).addEventListener('click',()=>{lang=l;try{localStorage.setItem('kas_lang',l)}catch(_){}draw();});
el('refresh').addEventListener('click',refresh);
el('run').addEventListener('click',runDoctor);
async function exportProviders(){
 if(exporting)return;
 exporting=true;providerMessage='';draw();
 try{
  const response=await fetch('/api/providers/names',{cache:'no-store',credentials:'same-origin'});
  if(!response.ok){
   if(response.status===404){providerMessage=t('providersDisabled');return;}
   let code='HTTP_'+response.status;
   try{const error=await response.json();code=error.error_code||code;}catch(_){}
   providerMessage=t('providersError',{code});return;
  }
  const file=await response.blob();
  if(file.size>1024*1024){providerMessage=t('providersError',{code:'RESPONSE_TOO_LARGE'});return;}
  const url=URL.createObjectURL(file);
  const a=document.createElement('a');
  a.href=url;a.download='mihomo-providers-names.json';
  document.body.appendChild(a);a.click();a.remove();
  setTimeout(()=>URL.revokeObjectURL(url),1000);
  providerMessage=t('providersSuccess');
 }catch(_){providerMessage=t('providersError',{code:'NETWORK_ERROR'});}
 finally{exporting=false;draw();}
}
// Read-only staged filter editor. Do not persist node names or raw provider JSON.
function renderFilterNodes(){
 const selector=el('filter-provider');
 const providers=(filterInspect?.providers||[]).filter(p=>p.http);
 selector.replaceChildren();
 for(const provider of providers){
  const o=document.createElement('option');o.value=provider.name;o.textContent=provider.name;selector.appendChild(o);
 }
 if(!providers.some(p=>p.name===filterSelectedProvider))filterSelectedProvider=providers[0]?.name||'';
 selector.value=filterSelectedProvider;selector.disabled=!filterSelectedProvider;
 const chosen=providers.find(p=>p.name===filterSelectedProvider);
 set('filter-existing',chosen?t('filterExisting',{filter:chosen.has_filter?chosen.existing_filter:t('filterNoFilter')}):t('filterNoProvider'));
 const list=el('filter-node-list');list.replaceChildren();
 const available=filterNodes?.providers?.[filterSelectedProvider]?.proxies||[];
 const names=[...new Set(available.map(p=>p.name).filter(x=>typeof x==='string'&&x))];
 for(const name of names.slice(0,400)){
  const label=document.createElement('label');label.style.display='block';
  const check=document.createElement('input');check.type='checkbox';check.value=name;
  label.appendChild(check);label.appendChild(document.createTextNode(' '+name));
  list.appendChild(label);
 }
 if(names.length===0){const tip=document.createElement('p');tip.textContent=t('filterNoNames');list.appendChild(tip);}
 if(names.length>400){const tip=document.createElement('p');tip.textContent=t('filterTooMany',{count:400});list.appendChild(tip);}
 draw();
}
async function loadFilterEditor(){
 if(filterLoading)return;
 filterLoading=true;filterStatus='';set('filter-result','');draw();
 try{
  const [a,b]=await Promise.all([
   fetch('/api/filter/providers',{cache:'no-store'}),
   fetch('/api/providers/names',{cache:'no-store'})
  ]);
  if(!a.ok||!b.ok){
   let code='HTTP_'+(!a.ok?a.status:b.status);
   try{const data=await (!a.ok?a:b).json();code=data.error_code||code;}catch(_){}
   throw Error(code);
  }
  filterInspect=await a.json();filterNodes=await b.json();
  filterStatus=t('filterLoaded');renderFilterNodes();
 }catch(e){filterInspect=null;filterNodes=null;filterSelectedProvider='';filterStatus=t('filterCannotLoad',{code:e.message||'UNKNOWN'});el('filter-node-list').replaceChildren();el('filter-provider').replaceChildren();set('filter-existing','');}
 finally{filterLoading=false;draw();}
}
async function previewFilterChange(clear){
 if(!filterInspect||!filterSelectedProvider||filterBusy)return;
 const names=clear?[]:[...el('filter-node-list').querySelectorAll('input:checked')].map(el=>el.value);
 if(!clear&&!names.length){filterStatus=t('filterNothing');draw();return;}
 filterBusy=true;filterStatus=t('filterPreviewing');set('filter-result','');draw();
 try{
  const response=await fetch('/api/filter/preview',{
   method:'POST',cache:'no-store',headers:{'Content-Type':'application/json','X-KAS-Confirm':'preview'},
   body:JSON.stringify({provider:filterSelectedProvider,names,clear,source_sha:filterInspect.source_sha})
  });
  const data=await response.json();
  if(!response.ok)throw Error(data.error_code||'HTTP_'+response.status);
  set('filter-result',t('filterProposed',{before:data.existing_filter||t('filterNoFilter'),after:data.proposed_filter||t('filterNoFilter')}));
  filterStatus=t('filterPreviewReady');
 }catch(e){filterStatus=t('filterPreviewError',{code:e.message||'UNKNOWN'});}
 finally{filterBusy=false;draw();}
}
el('filter-load').addEventListener('click',loadFilterEditor);
el('filter-provider').addEventListener('change',()=>{filterSelectedProvider=el('filter-provider').value;filterStatus='';set('filter-result','');renderFilterNodes();});
el('filter-preview').addEventListener('click',()=>previewFilterChange(false));
el('filter-clear').addEventListener('click',()=>previewFilterChange(true));

el('apply').addEventListener('click',applyYAML);
el('providers-download').addEventListener('click',exportProviders);
el('copy').addEventListener('click',async()=>{if(!doctorData?.details)return;try{await navigator.clipboard.writeText(doctorData.details)}catch(_){}});
draw();refresh();refreshImport();
