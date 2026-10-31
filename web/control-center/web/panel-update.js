'use strict';
(function(root){
 const words={
  ru:{heading:"Обновление KAS WEB",help:"Проверяйте и устанавливайте новые версии панели вручную. Во время установки соединение ненадолго прервётся. Настройки сохраняются, автоматического отката нет.",check:"Проверить обновления панели",apply:"Обновить панель",none:"Обновления панели ещё не проверялись.",unpublished:"Стабильная версия KAS WEB пока не выпущена. Выберите канал «Бета-версии», чтобы проверить доступные обновления.",checking:"Проверяем доступные версии KAS WEB…",available:"Установлено: {installed}. Запущено: {runtime}. Доступно: {available}. Канал: {channel}.",same:"В выбранном канале более новой версии нет.",newer:"Доступно обновление панели. Нажмите «Обновить панель».",confirm:"Установить обновление KAS WEB? Соединение с панелью временно прервётся. Настройки и порт сохраняются. Автоматического отката нет. Не выключайте роутер во время установки.",running:"Обновление панели выполняется. Этап: {phase}. Ожидаем восстановления соединения…",success:"Обновление завершено. Запущена новая версия: {version}.",failed:"Обновление панели не завершено. Причина: {code}.",error:"Не удалось проверить обновления KAS WEB: {code}.",waiting:"Ожидаем подтверждения новой операции. Результат предыдущего обновления не учитывается.",unverified:"Панель доступна, но новая версия ещё не подтверждена. Установка могла продолжиться. Проверьте состояние позднее.",recovery:"Обновление панели прервалось. {code}",previous:"Предыдущее обновление завершено. Перед следующей установкой проверьте доступную версию.",cancelled:"Обновление отменено. Установка не начиналась.",channelLabel:"Канал обновлений",channelExperimental:"Бета-версии",channelStable:"Стабильные версии",channelNote:"Смена канала не запускает установку. После выбора канала нажмите «Проверить обновления панели».",channelSaved:"Выбран канал «{channel}». Проверьте наличие обновлений.",channelError:"Не удалось переключить канал: {code}. Выбран прежний канал.",technical:"Технические сведения"},
  en:{heading:'KAS panel update',help:'Manually update the panel itself. Settings are preserved. The panel disconnects briefly during installation. There is no automatic rollback.',check:'Check panel version',apply:'Update panel',none:'No check has been run.',unpublished:'No stable KAS WEB release has been published yet. Choose “Beta versions” to check for updates.',checking:'Checking panel version…',available:'Installed: {installed}. Running: {runtime}. Available: {available}. Channel: {channel}.',same:'The selected channel offers no newer version.',newer:'A newer version is available. Use “Update panel”.',confirm:'Update the KAS panel? The connection will drop during installation. Settings and port are preserved. Do not power off the router. There is no automatic rollback.',running:'Panel update: {phase}. Waiting to reconnect…',success:'Panel updated. New running version verified: {version}.',failed:'The panel update did not complete. Reason: {code}.',error:'Unable to check the panel: {code}.',waiting:'Waiting for a new operation to be confirmed. The previous result does not count for this request.',unverified:'The panel responds, but the new version is not yet verified. Reload later; installation may have continued.',recovery:'The panel update was interrupted. {code}',previous:'A previous operation completed. Check the version before starting a new update.',cancelled:'Update cancelled before starting.',channelLabel:'Update channel',channelExperimental:'Beta versions',channelStable:'Stable versions',channelNote:'Changing the channel never starts a check or install by itself. Run “Check panel version” afterwards.',channelSaved:'Update channel selected: {channel}. Run the version check.',channelError:'Unable to change the channel: {code}. The channel stayed unchanged.',technical:'Technical details'}
 };
 // Show actionable explanations instead of raw internal backend error codes.
 // The unchanged error code stays available in a separate details element.
 const errorDescriptions={
  ru:{
   PANEL_DOWNLOAD_FAILED:'Не удалось загрузить сведения об обновлении с GitHub. Проверьте подключение к Интернету и повторите попытку.',
   PANEL_METADATA_INVALID:'Данные о выпуске не прошли проверку. Установка заблокирована.',
   PANEL_PACKAGE_INVALID:'Пакет обновления не прошёл проверку. Установка заблокирована.',
   PANEL_IDENTITY_MISMATCH:'Установленный пакет панели не совпадает с запущенной версией. Проверьте состояние через SSH.',
   PANEL_CHANNEL_UNPUBLISHED:'Выбранный канал обновлений ещё не опубликован.',
   PANEL_INSUFFICIENT_SPACE:'На накопителе недостаточно места для обновления. Освободите место в Entware и повторите попытку.',
   PANEL_SPACE_UNVERIFIED:'Не удалось проверить свободное место на накопителе. Установка не начиналась.',
   PANEL_OPKG_FAILED:'Ошибка установки пакета через opkg. Проверьте состояние панели через SSH.',
   PANEL_OPKG_BUSY_OR_UNKNOWN:'Менеджер пакетов opkg занят или его состояние неизвестно. Проверьте через SSH.',
   PANEL_OPKG_UNAVAILABLE:'Менеджер пакетов opkg недоступен. Проверьте Entware.',
   PANEL_START_FAILED:'Новая версия панели не запустилась. Проверьте состояние через SSH.',
   PANEL_RUNTIME_UNVERIFIED:'Не удалось подтвердить запуск новой версии панели. Проверьте состояние через SSH.',
   PANEL_NOT_PACKAGE_OWNED:'Панель установлена не как штатный пакет Entware. Обновление из браузера недоступно.',
   PANEL_CONFIG_CHANGED:'Во время проверки изменились файлы настроек. Установка остановлена, повторите проверку.',
   PANEL_REDIRECT_BLOCKED:'Ссылка для скачивания не прошла проверку безопасности. Загрузка остановлена.',
   PANEL_FILE_UNSAFE:'Файлы панели не прошли проверку безопасности. Проверьте установку через SSH.',
   PANEL_VERSION_UNVERIFIED:'Не удалось подтвердить версию установленного пакета. Обновление остановлено.',
   PANEL_CHANNEL_UNKNOWN:'Выбран неизвестный канал обновлений.',
   PANEL_RECOVERY_REQUIRED:'Продолжить установку из браузера невозможно. Проверьте и восстановите панель через SSH.',
   PANEL_UPDATE_FAILED:'Не удалось завершить проверку или установку обновления. Проверьте состояние панели.',
   BUSY:'Сейчас выполняется другая операция. Повторите попытку после её завершения.',
   PANEL_UPDATE_BUSY:'Сейчас выполняется другая операция. Повторите попытку после её завершения.',
   CHECK_REQUIRED:'Сначала проверьте наличие новой версии панели.',
   OPERATION_STATE_UNAVAILABLE:'Не удалось получить состояние предыдущей операции. Установка не начата.',
   REQUEST_BLOCKED:'Запрос отклонён проверкой безопасности. Обновите страницу и повторите попытку.',
   HTTP_502:'Сервер панели не смог получить сведения об обновлении.',
   INVALID_CHECK_STATE:'Панель получила неожиданный ответ. Повторите проверку обновлений.'
  },
  en:{
   PANEL_DOWNLOAD_FAILED:'Could not retrieve update information from GitHub. Check the Internet connection and try again.',
   PANEL_METADATA_INVALID:'The release metadata failed authenticity and integrity checks. Installation is blocked.',
   PANEL_PACKAGE_INVALID:'The update package failed verification. Installation is blocked.',
   PANEL_IDENTITY_MISMATCH:'The installed panel package does not match the running version. Inspect its state through SSH.',
   PANEL_CHANNEL_UNPUBLISHED:'The selected update channel has not been published yet.',
   PANEL_INSUFFICIENT_SPACE:'Not enough storage space for the update. Free up Entware storage and try again.',
   PANEL_SPACE_UNVERIFIED:'Could not verify free storage space. Installation was not started.',
   PANEL_OPKG_FAILED:'opkg could not install the package. Inspect panel state through SSH.',
   PANEL_OPKG_BUSY_OR_UNKNOWN:'The opkg package manager is busy or its state is unknown. Check through SSH.',
   PANEL_OPKG_UNAVAILABLE:'The opkg package manager is unavailable. Check Entware.',
   PANEL_START_FAILED:'The new panel version failed to start. Inspect its state through SSH.',
   PANEL_RUNTIME_UNVERIFIED:'Could not verify that the new panel version is running. Check through SSH.',
   PANEL_NOT_PACKAGE_OWNED:'The panel is not installed as a standard Entware package. Browser updates are unavailable.',
   PANEL_CONFIG_CHANGED:'Configuration files changed during verification. Installation stopped; check again.',
   PANEL_REDIRECT_BLOCKED:'The download link failed security verification. Download blocked.',
   PANEL_FILE_UNSAFE:'Panel files failed a safety check. Inspect the installation through SSH.',
   PANEL_VERSION_UNVERIFIED:'Could not verify the installed package version. Update halted.',
   PANEL_CHANNEL_UNKNOWN:'Unknown update channel.',
   PANEL_RECOVERY_REQUIRED:'Browser-side installation cannot continue. Inspect and recover the panel through SSH.',
   PANEL_UPDATE_FAILED:'The update check or installation could not be completed. Verify the panel state.',
   BUSY:'Another operation is running. Try again after it finishes.',
   PANEL_UPDATE_BUSY:'Another operation is running. Try again after it finishes.',
   CHECK_REQUIRED:'Check for a new panel version before installing.',
   OPERATION_STATE_UNAVAILABLE:'Could not read the previous operation state. Installation was not started.',
   REQUEST_BLOCKED:'The request was blocked by a security check. Reload the page and try again.',
   HTTP_502:'The panel server could not retrieve update information.',
   INVALID_CHECK_STATE:'The panel received an unexpected response. Try the update check again.'
  }
 };
 function explainError(code,language){
  if(typeof code!=='string'||!code)return language==='ru'?'Неизвестная ошибка.':'Unknown error.';
  const known=errorDescriptions[language]||errorDescriptions.en;
  if(known[code])return known[code];
  if(/^HTTP_/.test(code))return language==='ru'?'Сервер вернул ошибку. Повторите попытку или проверьте подключение.':'The server returned an error. Try again or check connectivity.';
  return language==='ru'?'Объяснение для этой ошибки недоступно. Подробности — в технических сведениях ниже.':'No explanation is available for this error. See the technical details below.';
 }
 const phaseNames={
  ru:{queued:'Подготовка',download:'Загрузка пакета',install:'Установка пакета',starting:'Запуск новой версии',complete:'Завершение',recovered:'Восстановление'},
  en:{queued:'Preparing',download:'Downloading package',install:'Installing package',starting:'Starting new version',complete:'Finishing',recovered:'Recovering'}
 };
 function humanPhase(phase,language){
  return (phaseNames[language]||phaseNames.en)[phase]||(language==='ru'?'Выполняется операция':'Processing');
 }
 const validID=id=>typeof id==='string'&&/^[a-f0-9]{24}$/.test(id);
 const validChannel=c=>c==='experimental'||c==='stable';
 function acceptPanelOperation(beforeID,op,submitted){return validID(op?.ID)&&(!submitted||op.ID!==beforeID);}
 function verifiedPanelReturn(op,components){return op?.State==='OK'&&op.Gate===false&&typeof op.Version==='string'&&/^[a-f0-9]{40}$/.test(op.SourceSHA)&&components?.panel?.version===op.Version&&components.panel.source_sha===op.SourceSHA;}
 // Display-only public form of an internal Entware package version:
 // "0.1.0~beta.2-1" → "v0.1.0-beta.2" (v prefix, prerelease dash, packaging revision dropped).
 // Never used for comparison, update decisions or API payloads; unknown values pass through unchanged.
 function publicVersion(raw){
  if(typeof raw!=='string')return raw;
  const value=raw.trim();
  if(/^[vV]/.test(value)||!/^[0-9]/.test(value))return value;
  return 'v'+value.replace(/-\d+$/,'').split('~').join('-');
 }
 function mount(options){
  const el=id=>document.getElementById(id);
  let check=null,working=false,checking=false,op=null,message={key:'none'},timer=null,attempts=0,beforeID='',submitted=false,expectedID='',tracking=false,channel='',channelBusy=false;
  try{const saved=sessionStorage.getItem('kas_panel_update_id')||'';if(saved.startsWith('pending:')&&(saved.slice(8)===''||validID(saved.slice(8)))){beforeID=saved.slice(8);submitted=true;working=true;tracking=true;message={key:'waiting'};}else if(validID(saved)){expectedID=saved;working=true;tracking=true;}}catch(_){}
  const t=(key,params={})=>(words[options.getLang()]||words.en)[key].replace(/\{(\w+)\}/g,(_,k)=>String(params[k]??''));
  const channelName=value=>value==='stable'?t('channelStable'):value==='experimental'?t('channelExperimental'):value;
  function draw(){
   for(const [id,key] of [['panel-update-heading','heading'],['panel-update-help','help'],['panel-update-check','check'],['panel-update-apply','apply']])el(id).textContent=t(key);
   el('panel-channel-label').textContent=t('channelLabel');
   el('panel-channel-experimental').textContent=t('channelExperimental');
   el('panel-channel-stable').textContent=t('channelStable');
   el('panel-channel-note').textContent=t('channelNote');
   el('panel-update-details-label').textContent=t('technical');
   el('panel-update-check').disabled=working||checking||options.isBusy();el('panel-update-apply').disabled=working||checking||options.isBusy()||check?.relation!=='newer';
   el('panel-channel').disabled=working||checking||channelBusy||options.isBusy();
   if(document.activeElement!==el('panel-channel'))el('panel-channel').value=channel;
   const rawCode=typeof message.params?.code==='string'?message.params.code:'';
   const details=['error','failed','recovery','channelError'].includes(message.key)&&rawCode;
   el('panel-update-details').hidden=!details;
   el('panel-update-error-code').textContent=details?rawCode:'';
   const params={...message.params,code:explainError(rawCode,options.getLang())};
   if(typeof params.channel==='string')params.channel=channelName(params.channel);
   if(typeof params.phase==='string')params.phase=humanPhase(params.phase,options.getLang());
   let text=checking?t('checking'):t(message.key,params);
   if(check?.state==='OK'&&!checking)text=t('available',{installed:publicVersion(check.installed_version||'?'),runtime:publicVersion(check.runtime_version||'?'),available:publicVersion(check.available_version||'?'),channel:channelName(check.channel||'?')})+' '+text;
   el('panel-update-state').textContent=text;
  }
  function occupy(value){working=value;options.onBusy(value);draw();}
  async function get(path){const response=await fetch(path,{cache:'no-store',credentials:'same-origin'});const data=await response.json();if(!response.ok)throw Error(data.error_code||'HTTP_'+response.status);return data;}
  // A 4xx answer proves the server refused the request before starting any
  // operation; such rejections are safe to show immediately. 5xx and network
  // failures stay ambiguous: the operation may have been accepted anyway.
  async function post(path,confirm){const response=await fetch(path,{method:'POST',cache:'no-store',credentials:'same-origin',headers:{'Content-Type':'application/json','X-KAS-Confirm':confirm},body:'{}'});const data=await response.json();if(!response.ok){const e=Error(data.error_code||'HTTP_'+response.status);if(response.status<500)e.definite=true;throw e;}return data;}
  function storeID(id){try{sessionStorage.setItem('kas_panel_update_id',id);}catch(_){}}
  function finish(clearID=false){clearTimeout(timer);timer=null;if(clearID){try{sessionStorage.removeItem('kas_panel_update_id');}catch(_){}}occupy(false);}
  function schedule(){clearTimeout(timer);if(++attempts>90){message={key:'unverified'};finish();return;}timer=setTimeout(poll,2000);}
  function applyChannelState(data){
   if(!validChannel(data.channel))return;
   channel=data.channel;
   const allowed=Array.isArray(data.allowed)?data.allowed.filter(validChannel):[];
   for(const value of ['experimental','stable'])el('panel-channel-'+value).hidden=allowed.length>0&&!allowed.includes(value)&&data.channel!==value;
   draw();
  }
  async function loadChannel(){
   try{applyChannelState(await get('/api/updates/panel/channel'));}
   catch(_){/* status only; the panel stays on its current channel */}
  }
  async function poll(){
   try{
    const data=await get('/api/updates/panel/operation');
    if((expectedID&&data.ID!==expectedID)||!acceptPanelOperation(beforeID,data,submitted)){if(data.error_code==='PANEL_RECOVERY_REQUIRED'){message={key:'recovery',params:{code:data.error_code}};occupy(true);}else if(working){message={key:'waiting'};schedule();}draw();return;}
    op=data;if(data.State==='RUNNING'||tracking){expectedID=data.ID;storeID(data.ID);}
    if(data.State==='RUNNING'){tracking=true;
     message={key:'running',params:{phase:data.Phase||'?'}};occupy(true);schedule();
    }else if(data.State==='OK'){
     if(!tracking){message={key:'previous'};finish();draw();return;}
     const components=await get('/api/components');
     if(verifiedPanelReturn(data,components)){message={key:'success',params:{version:publicVersion(data.Version)}};finish(true);}
     else{message={key:'unverified'};occupy(true);schedule();}
    }else if(data.State==='FAIL'){
     message={key:data.Gate?'recovery':'failed',params:{code:data.ErrorCode||'UNKNOWN'}};finish();
     if(data.Gate){occupy(true);check=null;el('panel-update-apply').disabled=true;}else{try{sessionStorage.removeItem('kas_panel_update_id');}catch(_){}}
    }else{message={key:'unverified'};if(working)schedule();}
   }catch(_){if(working)schedule();}
   draw();
  }
  async function runCheck(){
   if(checking||working||options.isBusy())return;checking=true;check=null;draw();
   try{
    check=await post('/api/updates/panel/check','check-panel');
    if(check.state==='UNPUBLISHED'&&check.channel==='stable'){message={key:'unpublished'};}
    else if(check.state==='OK'){message={key:check.relation==='newer'?'newer':'same'};}
    else{check=null;throw Error('INVALID_CHECK_STATE');}
   }
   catch(e){message={key:'error',params:{code:e.message}};}
   finally{checking=false;draw();}
  }
  async function changeChannel(){
   const next=el('panel-channel').value;
   if(!validChannel(next)||next===channel||channelBusy||working||checking||options.isBusy()){el('panel-channel').value=channel;draw();return;}
   const previous=channel;channelBusy=true;draw();
   try{
    const response=await fetch('/api/updates/panel/channel',{method:'POST',cache:'no-store',credentials:'same-origin',headers:{'Content-Type':'application/json','X-KAS-Confirm':'set-panel-channel'},body:JSON.stringify({channel:next})});
    const data=await response.json();
    if(!response.ok)throw Error(data.error_code||'HTTP_'+response.status);
    applyChannelState(data);
    check=null;message={key:'channelSaved',params:{channel}};
   }catch(e){channel=previous;el('panel-channel').value=channel;message={key:'channelError',params:{code:e.message}};}
   finally{channelBusy=false;draw();}
  }
  async function apply(){
   if(check?.relation!=='newer'||working||options.isBusy())return;
   if(!window.confirm(t('confirm'))){message={key:'cancelled'};draw();return;}
   try{const previous=await get('/api/updates/panel/operation');beforeID=previous.ID||'';}
   catch(e){message={key:'failed',params:{code:'OPERATION_STATE_UNAVAILABLE'}};draw();return;}
   submitted=true;tracking=true;expectedID='';storeID('pending:'+beforeID);attempts=0;message={key:'waiting'};occupy(true);check=null;
   try{const result=await post('/api/updates/panel/apply','update-panel');if(!validID(result.id))throw Error('INVALID_OPERATION');expectedID=result.id;storeID(result.id);}
   catch(e){
    // A definite refusal (BUSY, CHECK_REQUIRED, blocked request) means the
    // server never started this job: report it now instead of waiting out the
    // poll budget for an operation that will never appear.
    if(e&&e.definite){try{sessionStorage.removeItem('kas_panel_update_id');}catch(_){}submitted=false;tracking=false;expectedID='';message={key:'failed',params:{code:e.message}};occupy(false);draw();return;}
    /* Otherwise the server may have accepted the request before disconnecting. */
   }
   schedule();
  }
  el('panel-update-check').addEventListener('click',runCheck);el('panel-update-apply').addEventListener('click',apply);el('panel-channel').addEventListener('change',changeChannel);draw();
  // Local status only; opening the panel never checks GitHub for updates.
  if(working)options.onBusy(true);poll();loadChannel();return {draw};
 }
 const api={words,acceptPanelOperation,verifiedPanelReturn,validChannel,mount};
 if(typeof module!=='undefined'&&module.exports)module.exports=api;else root.KASPanelUpdate=api;
})(typeof window==='undefined'?globalThis:window);
