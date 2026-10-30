'use strict';
(function(root){
 const words={
  ru:{heading:"Обновление KAS WEB",help:"Проверяйте и устанавливайте новые версии панели вручную. Во время установки соединение ненадолго прервётся. Настройки сохраняются, автоматического отката нет.",check:"Проверить обновления панели",apply:"Обновить панель",none:"Обновления панели ещё не проверялись.",checking:"Проверяем доступные версии KAS WEB…",available:"Установлено: {installed}. Запущено: {runtime}. Доступно: {available}. Канал: {channel}.",same:"В выбранном канале более новой версии нет.",newer:"Доступно обновление панели. Нажмите «Обновить панель».",confirm:"Установить обновление KAS WEB? Соединение с панелью временно прервётся. Настройки и порт сохраняются. Автоматического отката нет. Не выключайте роутер во время установки.",running:"Устанавливаем обновление: {phase}. Ожидаем восстановления соединения…",success:"Обновление завершено. Запущена новая версия: {version}.",failed:"Подтвердить обновление панели не удалось: {code}. Если установка прервалась, проверьте состояние через SSH.",error:"Не удалось проверить обновления KAS WEB: {code}.",waiting:"Ожидаем подтверждения новой операции. Результат предыдущего обновления не учитывается.",unverified:"Панель доступна, но новая версия ещё не подтверждена. Установка могла продолжиться. Проверьте состояние позднее.",recovery:"Обновление прервалось или требуется восстановление через SSH: {code}.",previous:"Предыдущее обновление завершено. Перед следующей установкой проверьте доступную версию.",cancelled:"Обновление отменено. Установка не начиналась.",channelLabel:"Канал обновлений",channelExperimental:"Бета-версии",channelStable:"Стабильные версии",channelNote:"Смена канала не запускает установку. После выбора канала нажмите «Проверить обновления панели».",channelSaved:"Выбран канал «{channel}». Проверьте наличие обновлений.",channelError:"Не удалось переключить канал: {code}. Выбран прежний канал."},
  en:{heading:'KAS panel update',help:'Manually update the panel itself. Settings are preserved. The panel disconnects briefly during installation. There is no automatic rollback.',check:'Check panel version',apply:'Update panel',none:'No check has been run.',checking:'Checking panel version…',available:'Installed: {installed}. Running: {runtime}. Available: {available}. Channel: {channel}.',same:'The selected channel offers no newer version.',newer:'A newer version is available. Use “Update panel”.',confirm:'Update the KAS panel? The connection will drop during installation. Settings and port are preserved. Do not power off the router. There is no automatic rollback.',running:'Panel update: {phase}. Waiting to reconnect…',success:'Panel updated. New running version verified: {version}.',failed:'Panel update not verified: {code}. An incomplete installation may require checking through SSH.',error:'Unable to check the panel: {code}.',waiting:'Waiting for a new operation to be confirmed. The previous result does not count for this request.',unverified:'The panel responds, but the new version is not yet verified. Reload later; installation may have continued.',recovery:'Update interrupted or requires recovery through SSH: {code}.',previous:'A previous operation completed. Check the version before starting a new update.',cancelled:'Update cancelled before starting.',channelLabel:'Update channel',channelExperimental:'Beta (experimental)',channelStable:'Stable',channelNote:'Changing the channel never starts a check or install by itself. Run “Check panel version” afterwards.',channelSaved:'Update channel selected: {channel}. Run the version check.',channelError:'Unable to change the channel: {code}. The channel stayed unchanged.'}
 };
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
  function draw(){
   for(const [id,key] of [['panel-update-heading','heading'],['panel-update-help','help'],['panel-update-check','check'],['panel-update-apply','apply']])el(id).textContent=t(key);
   el('panel-channel-label').textContent=t('channelLabel');
   el('panel-channel-experimental').textContent=t('channelExperimental');
   el('panel-channel-stable').textContent=t('channelStable');
   el('panel-channel-note').textContent=t('channelNote');
   el('panel-update-check').disabled=working||checking||options.isBusy();el('panel-update-apply').disabled=working||checking||options.isBusy()||check?.relation!=='newer';
   el('panel-channel').disabled=working||checking||channelBusy||options.isBusy();
   if(document.activeElement!==el('panel-channel'))el('panel-channel').value=channel;
   let text=checking?t('checking'):t(message.key,message.params);
   if(check&&!checking)text=t('available',{installed:publicVersion(check.installed_version||'?'),runtime:publicVersion(check.runtime_version||'?'),available:publicVersion(check.available_version||'?'),channel:check.channel||'?'})+' '+text;
   el('panel-update-state').textContent=text;
  }
  function occupy(value){working=value;options.onBusy(value);draw();}
  async function get(path){const response=await fetch(path,{cache:'no-store',credentials:'same-origin'});const data=await response.json();if(!response.ok)throw Error(data.error_code||'HTTP_'+response.status);return data;}
  async function post(path,confirm){const response=await fetch(path,{method:'POST',cache:'no-store',credentials:'same-origin',headers:{'Content-Type':'application/json','X-KAS-Confirm':confirm},body:'{}'});const data=await response.json();if(!response.ok)throw Error(data.error_code||'HTTP_'+response.status);return data;}
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
   try{check=await post('/api/updates/panel/check','check-panel');message={key:check.relation==='newer'?'newer':'same'};}
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
   catch(_){/* The server may have accepted the request before disconnecting. */}
   schedule();
  }
  el('panel-update-check').addEventListener('click',runCheck);el('panel-update-apply').addEventListener('click',apply);el('panel-channel').addEventListener('change',changeChannel);draw();
  // Local status only; opening the panel never checks GitHub for updates.
  if(working)options.onBusy(true);poll();loadChannel();return {draw};
 }
 const api={words,acceptPanelOperation,verifiedPanelReturn,validChannel,mount};
 if(typeof module!=='undefined'&&module.exports)module.exports=api;else root.KASPanelUpdate=api;
})(typeof window==='undefined'?globalThis:window);
