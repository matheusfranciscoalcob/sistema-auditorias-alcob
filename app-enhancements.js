(function(){
'use strict';
var app=window.AlcobApp;
if(!app)return;
var $=function(id){return document.getElementById(id)};
var subsetLabels={roda:'Roda',laminacao:'Laminação',bobinador:'Bobinador'};
var originLabels={auditoria:'Auditoria',kaizen:'Kaizen',avaliacao_processo:'Avaliação de processo',conversa:'Conversa',reuniao:'Reunião','':'Sem origem'};
var editingOperatorAudit=null;

function html(value){return app.esc(value)}
function key(value){return app.personKey(value)}
function sectorLabel(value){return app.types[value]?app.types[value].label:value}
function activeAdmin(){return !!app.adminPassword}
function selectAllTabs(id,buttonId){
  document.querySelectorAll('.tab-content').forEach(function(item){item.classList.remove('active')});
  document.querySelectorAll('.tab-btn').forEach(function(item){item.classList.remove('active')});
  if($(id))$(id).classList.add('active');
  if($(buttonId))$(buttonId).classList.add('active');
}

/* ------------------------------------------------------------------------ */
/* Dashboard: recarrega o histórico online e usa o nome canônico atual.     */
/* ------------------------------------------------------------------------ */

function qualityTeams(scores){
  var seen={},rows=[];
  scores.filter(function(item){return item.process==='Qualidade / Laboratório'}).sort(function(a,b){
    return MONTHS.indexOf(a.month)-MONTHS.indexOf(b.month)||a.week-b.week;
  }).forEach(function(item){if(!seen[item.team]&&rows.length<8){seen[item.team]=true;rows.push(item.team)}});
  return rows;
}
function renderQualityChart(){
  var canvas=$('cEvoLab');
  if(!canvas||typeof buildEvo!=='function')return;
  buildEvo('cEvoLab',gas(),qualityTeams(gas()),['#16a34a','#0ea5e9','#8b5cf6','#f59e0b','#db2777','#0891b2','#65a30d','#c2410c'],'Qualidade / Laboratório','Qualidade / Laboratório | Evolução das auditorias salvas');
  var title=canvas.closest('.dash-card')&&canvas.closest('.dash-card').querySelector('h3');
  if(title)title.textContent='📈 Evolução Qualidade / Laboratório';
}
var baseRefreshDash=window.refreshDash;
window.refreshDash=function(){baseRefreshDash();renderQualityChart()};

async function refreshPublicAudits(){
  if(activeAdmin())return;
  try{
    var response=await fetch('https://rkejqjjnlmgdhcxzrfcg.supabase.co/rest/v1/auditoria_resultados?select=*&order=created_at.asc',{headers:app.headers()});
    if(!response.ok)return;
    var rows=await response.json();
    app.setLocal(rows.map(function(row){
      var role=row.audited_role||'supervisor';
      return{id:Number(row.audit_id),type:row.type,team:row.team,date:row.audit_date,cargo:row.cargo||'',score:Number(row.score),totalOk:Number(row.total_ok||0),totalNo:Number(row.total_no||0),supervisorName:row.supervisor_name||(role==='supervisor'?row.team:''),auditedRole:role,subsetor:row.subsetor||null};
    }));
    if(window.rebuildAuditDashboard)window.rebuildAuditDashboard();
    window.refreshDash();
  }catch(_){}
}

/* ------------------------------------------------------------------------ */
/* Cadastro operacional e matriz por subsetor da Laminação.                 */
/* ------------------------------------------------------------------------ */

function installHierarchySubsetor(){
  var sector=$('hierarchy-sector');
  if(!sector||$('hierarchy-subsector'))return;
  var label=document.createElement('label');
  label.className='subsector-field';
  label.id='hierarchy-subsector-wrap';
  label.innerHTML='SUBSETOR DA LAMINAÇÃO *<select id="hierarchy-subsector"><option value="roda">Roda</option><option value="laminacao" selected>Laminação</option><option value="bobinador">Bobinador</option></select>';
  sector.closest('label').insertAdjacentElement('afterend',label);
  sector.addEventListener('change',syncHierarchySubsetor);
  syncHierarchySubsetor();
}
function syncHierarchySubsetor(){
  var wrap=$('hierarchy-subsector-wrap'),sector=$('hierarchy-sector');
  if(!wrap||!sector)return;
  wrap.classList.toggle('enhancement-hidden',sector.value!=='laminacao');
}
function decorateSubordinationTable(){
  var table=document.querySelector('#hierarchy-list .hierarchy-table');
  if(!table)return;
  var head=table.querySelector('thead tr');
  if(head&&!head.querySelector('.subsetor-column')){
    var th=document.createElement('th');th.className='subsetor-column';th.textContent='Subsetor';
    head.children[0].insertAdjacentElement('afterend',th);
  }
  table.querySelectorAll('tbody tr').forEach(function(row,index){
    if(row.querySelector('.subsetor-column'))return;
    var item=app.subordinations[index],td=document.createElement('td');
    td.className='subsetor-column';
    td.innerHTML=item&&item.setor==='laminacao'?'<span class="subsetor-badge">'+html(subsetLabels[item.subsetor]||'A definir')+'</span>':'—';
    row.children[0].insertAdjacentElement('afterend',td);
  });
}
var hierarchyObserver=$('hierarchy-list')?new MutationObserver(function(){decorateSubordinationTable()}):null;
if(hierarchyObserver)hierarchyObserver.observe($('hierarchy-list'),{childList:true,subtree:true});

var baseEditSubordination=window.editSubordination;
window.editSubordination=function(id){
  baseEditSubordination(id);
  var item=app.subordinations.find(function(row){return Number(row.id)===Number(id)});
  if($('hierarchy-subsector'))$('hierarchy-subsector').value=item&&item.subsetor||'laminacao';
  syncHierarchySubsetor();
};
var baseCancelSubordination=window.cancelSubordinationEdit;
window.cancelSubordinationEdit=function(){
  baseCancelSubordination();
  if($('hierarchy-subsector'))$('hierarchy-subsector').value='laminacao';
  syncHierarchySubsetor();
};
window.saveSubordination=async function(){
  if(!await app.ensureAdmin())return;
  var sector=$('hierarchy-sector').value,subsetor=sector==='laminacao'?$('hierarchy-subsector').value:null;
  var superior=$('hierarchy-supervisor').value.trim(),leader=superior&&app.leaders.find(function(item){return key(item.nome)===key(superior)});
  var data={p_password:app.adminPassword,p_id:app.editingSubordination?Number(app.editingSubordination.id):null,p_setor:sector,p_subsetor:subsetor,p_supervisor:leader?leader.nome:'',p_subordinado:$('hierarchy-subordinate').value.trim(),p_cargo:$('hierarchy-cargo').value.trim()};
  if(!data.p_subordinado||!data.p_cargo){toast('⚠️ Preencha colaborador e cargo.');return}
  if(sector==='laminacao'&&!subsetor){toast('⚠️ Selecione o subsetor da Laminação.');return}
  try{
    await app.rpc('save_subordinacao_v2',data);
    window.cancelSubordinationEdit();
    await app.loadSubordinations();
    decorateSubordinationTable();
    toast('✅ Colaborador cadastrado e liberado para a auditoria operacional.');
  }catch(error){toast('❌ Não foi possível salvar: '+error.message)}
};

var flexLevels=['Não apto','Em treinamento','Apto com supervisão','Apto sem supervisão','Apto a treinar'];
function installMatrixSubsetor(){
  var sector=$('matrix-sector-filter');
  if(!sector||$('matrix-subsector-filter'))return;
  var label=document.createElement('label');
  label.id='matrix-subsector-wrap';
  label.innerHTML='SUBSETOR<select id="matrix-subsector-filter"><option value="roda">Roda</option><option value="laminacao" selected>Laminação</option><option value="bobinador">Bobinador</option></select>';
  sector.closest('label').insertAdjacentElement('afterend',label);
  $('matrix-subsector-filter').addEventListener('change',function(){window.renderFlexMatrix(true)});
}
function matrixRowsFor(sector,subsetor){
  var map={};
  app.flexMatrixRows.forEach(function(row){
    if(row.setor!==sector)return;
    var rowSubset=row.atividade_subsetor||null;
    if(subsetor&&rowSubset!==subsetor)return;
    var id=Number(row.atividade_id);
    if(!map[id])map[id]={id:id,setor:row.setor,subsetor:rowSubset,ordem:Number(row.atividade_ordem),nome:row.atividade_nome};
  });
  return Object.keys(map).map(function(id){return map[id]}).sort(function(a,b){return a.ordem-b.ordem||a.id-b.id});
}
function matrixPeopleFor(sector,supervisor,subsetor){
  return app.subordinations.filter(function(item){
    return item.setor===sector&&(!subsetor||item.subsetor===subsetor)&&(supervisor==='all'||key(item.supervisor)===key(supervisor));
  }).sort(function(a,b){return String(a.supervisor||'').localeCompare(String(b.supervisor||''),'pt-BR')||a.subordinado.localeCompare(b.subordinado,'pt-BR')});
}
function matrixCell(personId,activityId){
  return app.flexMatrixRows.find(function(row){return Number(row.subordinacao_id)===Number(personId)&&Number(row.atividade_id)===Number(activityId)});
}
function enhancedMatrixMetrics(sector,supervisor,subsetor){
  var people=matrixPeopleFor(sector,supervisor||'all',subsetor||null);
  var activities=matrixRowsFor(sector,subsetor||null),filled=0,points=0,total=0;
  people.forEach(function(person){
    var applicable=sector==='laminacao'?activities.filter(function(activity){return activity.subsetor===person.subsetor}):activities;
    applicable.forEach(function(activity){
      total++;
      var row=matrixCell(person.id,activity.id);
      if(row&&row.nivel!==null&&row.nivel!==undefined){filled++;points+=Number(row.nivel)}
    });
  });
  return{activities:activities,people:people,total:total,filled:filled,score:total?points/(total*4)*100:null,coverage:total?filled/total*100:0};
}
app.setFlexMatrixMetrics(enhancedMatrixMetrics);
function matrixSupervisorOptions(sector,subsetor,current){
  var values=[];
  app.subordinations.forEach(function(item){
    if(item.setor===sector&&(!subsetor||item.subsetor===subsetor)&&item.supervisor&&values.every(function(value){return key(value)!==key(item.supervisor)}))values.push(item.supervisor);
  });
  values.sort(function(a,b){return a.localeCompare(b,'pt-BR')});
  return'<option value="all">Todos os superiores</option>'+values.map(function(value){return'<option value="'+html(value)+'"'+(key(value)===key(current)?' selected':'')+'>'+html(value)+'</option>'}).join('');
}
function matrixCellOptions(value){
  var out='<option value=""'+(value==null?' selected':'')+'>Não avaliado</option>';
  flexLevels.forEach(function(label,index){out+='<option value="'+index+'"'+(Number(value)===index?' selected':'')+'>'+index+' - '+html(label)+'</option>'});
  return out;
}
window.renderFlexMatrix=function(resetSupervisor){
  installMatrixSubsetor();
  var sector=$('matrix-sector-filter').value||'laminacao',subsetor=sector==='laminacao'?$('matrix-subsector-filter').value:null;
  $('matrix-subsector-wrap').classList.toggle('enhancement-hidden',sector!=='laminacao');
  var supervisorSelect=$('matrix-supervisor-filter'),current=resetSupervisor?'all':supervisorSelect.value||'all';
  supervisorSelect.innerHTML=matrixSupervisorOptions(sector,subsetor,current);
  if(Array.from(supervisorSelect.options).some(function(option){return option.value===current}))supervisorSelect.value=current;else supervisorSelect.value='all';
  var metrics=enhancedMatrixMetrics(sector,supervisorSelect.value,subsetor),editable=activeAdmin();
  $('matrix-score').textContent=metrics.score==null?'—':metrics.score.toFixed(2).replace('.',',')+' %';
  $('matrix-coverage').textContent=metrics.coverage.toFixed(0)+'%';
  $('matrix-people').textContent=metrics.people.length;
  $('matrix-activities').textContent=metrics.activities.length;
  $('matrix-admin-hint').textContent=editable?'Acesso administrativo ativo: edição liberada.':'Consulta pública; alterações exigem senha.';
  $('matrix-legend').innerHTML=flexLevels.map(function(label,index){return'<span class="matrix-level-badge matrix-level-'+index+'">'+index+' • '+html(label)+'</span>'}).join('');
  var target=$('matrix-table-wrap');
  if(!metrics.activities.length||!metrics.people.length){
    target.innerHTML='<div class="hierarchy-empty">'+(!metrics.activities.length?'Nenhuma atividade cadastrada neste recorte.':'Nenhum colaborador operacional cadastrado neste recorte.')+'</div>';
  }else{
    var minWidth=Math.max(900,290+metrics.activities.length*125);
    var head='<th class="matrix-person">Superior / colaborador</th>'+metrics.activities.map(function(activity){return'<th title="'+html(activity.nome)+'">'+html(activity.nome)+'</th>'}).join('')+'<th>Média</th>';
    var body=metrics.people.map(function(person){
      var sum=0,applicable=0;
      var cells=metrics.activities.map(function(activity){
        var allowed=sector!=='laminacao'||activity.subsetor===person.subsetor;
        if(!allowed)return'<td class="matrix-empty-level">—</td>';
        applicable++;
        var row=matrixCell(person.id,activity.id),value=row&&row.nivel!==null?Number(row.nivel):null;
        if(value!=null)sum+=value;
        return'<td class="'+(value==null?'matrix-empty-level':'matrix-level-'+value)+'"><select class="matrix-cell-select" '+(editable?'':'disabled')+' onchange="saveFlexLevel(this,'+person.id+','+activity.id+')">'+matrixCellOptions(value)+'</select></td>';
      }).join('');
      var average=applicable?sum/(applicable*4)*100:null;
      return'<tr><td class="matrix-person"><strong>'+html(person.subordinado)+'</strong><br><small>'+html(person.supervisor||'Sem superior')+' • '+html(person.cargo)+(person.subsetor?' • '+html(subsetLabels[person.subsetor]):'')+'</small></td>'+cells+'<td class="matrix-average">'+(average==null?'—':average.toFixed(2).replace('.',',')+' %')+'</td></tr>';
    }).join('');
    target.innerHTML='<table class="matrix-table" style="min-width:'+minWidth+'px"><thead><tr>'+head+'</tr></thead><tbody>'+body+'</tbody></table>';
  }
  var manager=$('matrix-activity-manager');
  if(!activeAdmin())manager.innerHTML='<h3>Atividades da matriz</h3><div style="font-size:9px;color:#64748b">A edição fica disponível no acesso administrativo.</div>';
  else manager.innerHTML='<h3>Gerenciar atividades de '+html(sector==='laminacao'?subsetLabels[subsetor]:sectorLabel(sector))+'</h3><div class="matrix-activity-list">'+(metrics.activities.length?metrics.activities.map(function(activity){return'<div class="matrix-activity-item"><span>'+activity.ordem+'. '+html(activity.nome)+'</span><button style="background:#fef3c7;color:#92400e" onclick="openFlexActivityForm('+activity.id+')">Editar</button><button style="background:#fee2e2;color:#b91c1c" onclick="deleteFlexActivity('+activity.id+')">Remover</button></div>'}).join(''):'<span style="font-size:9px;color:#64748b">Nenhuma atividade cadastrada.</span>')+'</div>';
};
window.changeFlexMatrixSector=function(){
  if($('matrix-subsector-filter'))$('matrix-subsector-filter').value='laminacao';
  window.renderFlexMatrix(true);
};
window.openFlexActivityForm=async function(id){
  if(!await app.ensureAdmin())return;
  var sector=$('matrix-sector-filter').value,subsetor=sector==='laminacao'?$('matrix-subsector-filter').value:null;
  var activities=matrixRowsFor(sector,subsetor),activity=id?activities.find(function(item){return item.id===Number(id)}):null;
  var name=prompt(activity?'Editar atividade da matriz:':'Nome da nova atividade:',activity?activity.nome:'');
  if(name===null)return;
  name=name.trim();if(!name){toast('⚠️ Informe o nome da atividade.');return}
  var order=activity?activity.ordem:(activities.length?Math.max.apply(null,activities.map(function(item){return item.ordem}))+10:10);
  try{
    await app.rpc('save_matriz_flexibilidade_atividade_v2',{p_password:app.adminPassword,p_id:activity?activity.id:null,p_setor:sector,p_subsetor:subsetor,p_nome:name,p_ordem:order});
    await window.loadFlexMatrix();toast('✅ Atividade da matriz salva.');
  }catch(error){toast('❌ Não foi possível salvar: '+error.message)}
};
var baseOpenSubordinateMatrix=window.openSubordinateMatrix;
window.openSubordinateMatrix=function(id){
  var item=app.subordinations.find(function(row){return Number(row.id)===Number(id)});
  baseOpenSubordinateMatrix(id);
  if(item&&item.setor==='laminacao'&&$('matrix-subsector-filter'))$('matrix-subsector-filter').value=item.subsetor||'laminacao';
  window.renderFlexMatrix(true);
  if(item&&item.supervisor)$('matrix-supervisor-filter').value=item.supervisor;
  window.renderFlexMatrix();
};

/* ------------------------------------------------------------------------ */
/* 5W2H: múltiplos responsáveis, ação-pai e filtro de status.                */
/* ------------------------------------------------------------------------ */

function installActionEnhancements(){
  var owner=$('action-quem');
  if(owner&&!$('action-responsibles')){
    var label=owner.closest('label');
    label.className='wide action-responsible-field';
    label.innerHTML='<span>QUEM? — COLABORADORES RESPONSÁVEIS *</span><input id="action-quem" type="hidden"><div class="action-responsible-search"><input id="action-responsible-search" type="search" autocomplete="off" placeholder="Pesquisar por nome, cargo ou setor..."><span id="action-responsible-count"></span></div><div class="action-responsible-picker" id="action-responsibles"></div>';
    $('action-responsible-search').addEventListener('input',filterActionResponsibles);
  }
  if(!$('action-parent')){
    var parentLabel=document.createElement('label');
    parentLabel.className='wide';
    parentLabel.innerHTML='DESDOBRAMENTO / ACOMPANHAMENTO DE — OPCIONAL<select id="action-parent"><option value="">Ação inicial / independente</option></select><small class="action-evidence-help">Selecione uma ação inicial para criar um desdobramento subordinado.</small>';
    $('action-o-que').closest('label').insertAdjacentElement('beforebegin',parentLabel);
  }
  if(!$('action-status-filter')){
    var label=document.createElement('label');
    label.innerHTML='FILTRAR POR STATUS<select id="action-status-filter" class="action-filter-select"><option value="all">Todos os status</option><option value="pending">Pendentes</option><option value="progress">Em andamento</option><option value="done">Concluídos</option><option value="late">Atrasados</option><option value="today">Vence hoje</option><option value="soon">Próximos 7 dias</option></select>';
    label.querySelector('select').addEventListener('change',function(){window.renderActionPlans()});
    $('action-sector-filter').closest('label').insertAdjacentElement('afterend',label);
  }
}
function actionResponsibleTokensFromNames(names){
  var wanted=String(names||'').split(',').map(key).filter(Boolean);
  return app.registeredPeople().filter(function(person){return wanted.indexOf(key(person.nome))>=0}).map(function(person){return person.token});
}
function renderActionResponsibles(selected){
  var target=$('action-responsibles');if(!target)return;
  var map={};(selected||[]).forEach(function(token){map[token]=true});
  var people=app.registeredPeople();
  target.innerHTML=people.length?people.map(function(person){
    return'<label data-action-responsible><input type="checkbox" value="'+html(person.token)+'"'+(map[person.token]?' checked':'')+'><span><strong>'+html(person.nome)+'</strong><br><small>'+html(person.cargo+' • '+(person.setor?sectorLabel(person.setor):''))+'</small></span></label>';
  }).join(''):'<div class="action-link-empty">Cadastre primeiro os colaboradores ou lideranças.</div>';
  target.querySelectorAll('input').forEach(function(input){input.addEventListener('change',updateActionResponsibleCount)});
  filterActionResponsibles();updateActionResponsibleCount();
}
function selectedActionResponsibles(){
  return Array.from(document.querySelectorAll('#action-responsibles input:checked')).map(function(input){return input.value});
}
function updateActionResponsibleCount(){
  if($('action-responsible-count'))$('action-responsible-count').textContent=selectedActionResponsibles().length+' selecionado(s)';
}
function filterActionResponsibles(){
  var query=key($('action-responsible-search')&&$('action-responsible-search').value),visible=0;
  document.querySelectorAll('#action-responsibles label[data-action-responsible]').forEach(function(label){
    var show=!query||key(label.textContent).indexOf(query)>=0;label.style.display=show?'':'none';if(show)visible++;
  });
  if($('action-responsible-count'))$('action-responsible-count').textContent=visible+' exibido(s) • '+selectedActionResponsibles().length+' selecionado(s)';
}
function renderActionParents(selected){
  var select=$('action-parent');if(!select)return;
  var sector=$('action-setor').value,current=app.editingActionPlan&&Number(app.editingActionPlan.id);
  var rows=app.actionPlans.filter(function(plan){return plan.setor===sector&&Number(plan.id)!==current});
  select.innerHTML='<option value="">Ação inicial / independente</option>'+rows.map(function(plan){return'<option value="'+plan.id+'"'+(Number(selected)===Number(plan.id)?' selected':'')+'>#'+plan.id+' — '+html(plan.o_que)+' — '+html(plan.status)+'</option>'}).join('');
}
var baseSyncActionLinks=window.syncActionPlanLinks;
window.syncActionPlanLinks=function(){
  var selected=selectedActionResponsibles();
  baseSyncActionLinks();
  renderActionResponsibles(selected);
  renderActionParents($('action-parent')&&$('action-parent').value);
};
var baseOpenActionPlan=window.openActionPlanForm;
window.openActionPlanForm=async function(id,suggestionId,parentId){
  installActionEnhancements();
  await baseOpenActionPlan(id,suggestionId);
  var plan=app.editingActionPlan,tokens=plan&&Array.isArray(plan.responsavel_tokens)&&plan.responsavel_tokens.length?plan.responsavel_tokens:actionResponsibleTokensFromNames(plan&&plan.quem);
  if(parentId){
    var parent=app.actionPlans.find(function(item){return Number(item.id)===Number(parentId)});
    if(parent){$('action-setor').value=parent.setor;app.renderActionLinkPickers([],[])}
  }
  $('action-responsible-search').value='';
  renderActionResponsibles(tokens);
  renderActionParents(parentId||plan&&plan.acao_pai_id||null);
};
window.openChildAction=function(parentId){return window.openActionPlanForm(null,null,Number(parentId))};
function actionResponsibleHtml(plan){
  var rows=Array.isArray(plan.responsaveis)?plan.responsaveis:[];
  if(!rows.length)return html(plan.quem||'—');
  return'<div class="action-link-badges">'+rows.map(function(person){return'<span class="action-link-badge">'+html(person.nome)+'</span>'}).join('')+'</div>';
}
function actionDepth(plan,seen){
  if(!plan||!plan.acao_pai_id)return 0;seen=seen||{};if(seen[plan.id])return 0;seen[plan.id]=true;
  return 1+actionDepth(app.actionPlans.find(function(item){return Number(item.id)===Number(plan.acao_pai_id)}),seen);
}
function actionMatchesStatus(plan,filter){
  var deadline=app.actionDeadlineInfo(plan);
  if(filter==='all')return true;
  if(filter==='pending')return plan.status==='Pendente'&&!(deadline&&deadline.category==='overdue');
  if(filter==='progress')return plan.status==='Em andamento'&&!(deadline&&deadline.category==='overdue');
  if(filter==='done')return plan.status==='Concluído';
  if(filter==='late')return !!(deadline&&deadline.category==='overdue');
  if(filter==='today')return !!(deadline&&deadline.category==='today');
  if(filter==='soon')return !!(deadline&&deadline.category==='soon');
  return true;
}
window.renderActionPlans=function(filter){
  installActionEnhancements();app.renderActionDeadlineAlerts();
  var sector=filter||$('action-sector-filter').value||'all',status=$('action-status-filter')?$('action-status-filter').value:'all';
  if($('action-sector-filter').value!==sector)$('action-sector-filter').value=sector;
  var plans=app.actionPlans.filter(function(plan){return(sector==='all'||plan.setor===sector)&&actionMatchesStatus(plan,status)});
  var late=plans.filter(function(plan){return app.statusInfo(plan).css==='late'}).length;
  $('action-total').textContent=plans.length;$('action-pending').textContent=plans.filter(function(plan){return plan.status==='Pendente'&&app.statusInfo(plan).css!=='late'}).length;
  $('action-progress').textContent=plans.filter(function(plan){return plan.status==='Em andamento'&&app.statusInfo(plan).css!=='late'}).length;
  $('action-done').textContent=plans.filter(function(plan){return plan.status==='Concluído'}).length;$('action-late').textContent=late;
  var list=$('action-plan-list');
  if(!plans.length){list.innerHTML='<div class="action-empty">Nenhuma ação encontrada para estes filtros.</div>';return}
  plans.sort(function(a,b){return actionDepth(a)-actionDepth(b)||String(a.quando||'9999').localeCompare(String(b.quando||'9999'))||Number(a.id)-Number(b.id)});
  list.innerHTML='<table class="action-table"><thead><tr><th>Setor</th><th>Desdobramento</th><th>Sugestão de origem</th><th>Supervisores vinculados</th><th>Auditorias vinculadas</th><th>O quê?</th><th>Por quê?</th><th>Onde?</th><th>Quando?</th><th>Quem?</th><th>Como?</th><th>Quanto?</th><th>Status</th><th>Evidências</th><th>Ações</th></tr></thead><tbody>'+plans.map(function(plan){
    var st=app.statusInfo(plan),depth=actionDepth(plan),parent=plan.acao_pai_id?'<span class="parent-action-badge">#'+plan.acao_pai_id+' • '+html(plan.acao_pai_o_que||'Ação inicial')+'</span>':'<span class="action-evidence-help">Ação inicial</span>';
    var actions=activeAdmin()?'<div class="action-row-actions"><button style="background:#dbeafe;color:#1d4ed8" onclick="openChildAction('+plan.id+')">↳ Desdobrar</button><button style="background:#fef3c7;color:#92400e" onclick="openActionPlanForm('+plan.id+')">✏️ Editar</button><button style="background:#fee2e2;color:#b91c1c" onclick="deleteActionPlan('+plan.id+')">✕ Excluir</button></div>':'Consulta';
    return'<tr class="'+app.actionDeadlineRowClass(plan)+(depth?' action-child-row':'')+'"><td class="action-sector">'+(depth?'<span class="action-depth">'+'↳'.repeat(Math.min(depth,3))+'</span>':'')+html(app.actionTypeLabel(plan.setor))+'</td><td>'+parent+'</td><td>'+app.actionPlanSuggestionHtml(plan)+'</td><td>'+app.actionPlanSupervisorsHtml(plan)+'</td><td>'+app.actionPlanAuditsHtml(plan)+'</td><td>'+html(plan.o_que)+'</td><td>'+html(plan.por_que||'—')+'</td><td>'+html(plan.onde||'—')+'</td><td>'+html(app.actionFormatDate(plan.quando))+app.actionDeadlineBadge(plan)+'</td><td>'+actionResponsibleHtml(plan)+'</td><td>'+html(plan.como||'—')+'</td><td>'+html(plan.quanto||'—')+'</td><td><span class="action-status '+st.css+'">'+st.label+'</span></td><td><div class="action-evidence-list">'+app.actionEvidenceHtml(plan.id,false)+'</div></td><td>'+actions+'</td></tr>';
  }).join('')+'</tbody></table>';
};
window.saveActionPlan=async function(){
  if(!await app.ensureAdmin())return;
  var files=Array.from($('action-evidence-files').files||[]),invalid=files.find(function(file){return!app.actionEvidenceMime(file)||!file.size||file.size>8388608});
  if(invalid){toast(!app.actionEvidenceMime(invalid)?'⚠️ Use somente PDF ou imagens.':'⚠️ Cada evidência deve ter no máximo 8 MB.');return}
  var suggestion=$('action-suggestion').value,responsibles=selectedActionResponsibles();
  if(!responsibles.length){toast('⚠️ Selecione pelo menos um colaborador cadastrado no campo Quem.');return}
  var data={p_password:app.adminPassword,p_id:app.editingActionPlan?Number(app.editingActionPlan.id):Date.now(),p_setor:$('action-setor').value,p_supervisores:app.actionSelectedValues('action-supervisores',false),p_auditoria_ids:app.actionSelectedValues('action-auditorias',true),p_sugestao_id:suggestion?Number(suggestion):null,p_acao_pai_id:$('action-parent').value?Number($('action-parent').value):null,p_responsaveis:responsibles,p_o_que:$('action-o-que').value.trim(),p_por_que:$('action-por-que').value.trim(),p_onde:$('action-onde').value.trim(),p_quando:$('action-quando').value||null,p_como:$('action-como').value.trim(),p_quanto:$('action-quanto').value.trim(),p_status:$('action-status').value};
  if(!data.p_setor||!data.p_o_que){toast('⚠️ Preencha o setor e o campo O QUÊ.');return}
  var button=document.querySelector('#action-plan-form .btn-save');button.disabled=true;button.textContent='Salvando...';
  try{
    await app.rpc('save_plano_acao_5w2h_v4',data);
    var failed=0,baseId=Date.now()*100;
    for(var i=0;i<files.length;i++){
      try{await app.rpc('save_evidencia_5w2h',{p_password:app.adminPassword,p_id:baseId+i,p_plano_id:data.p_id,p_nome:files[i].name.slice(0,255),p_mime_type:app.actionEvidenceMime(files[i]),p_conteudo_base64:await app.actionFileBase64(files[i])})}catch(_){failed++}
    }
    window.closeActionPlanForm();
    await Promise.all([window.loadActionPlans(),window.loadImprovementSuggestions()]);
    toast(failed?'⚠️ Ação salva, mas '+failed+' evidência(s) falharam.':data.p_acao_pai_id?'✅ Desdobramento salvo e vinculado à ação inicial.':'✅ Plano de ação salvo com os responsáveis cadastrados.');
  }catch(error){toast('❌ Não foi possível salvar: '+error.message)}
  finally{button.disabled=false;button.textContent='💾 Salvar plano'}
};

/* ------------------------------------------------------------------------ */
/* Sugestões: origem, filtros e avaliação do Kaizen pela Engenharia.         */
/* ------------------------------------------------------------------------ */

var suggestionStatuses=['Aguardando avaliação','Registrada','Em análise','Aprovada','Em implementação','Concluída','Não aprovada'];
app.setSuggestionStatuses(suggestionStatuses);
function originOptions(includeAll){
  var out=includeAll?'<option value="all">Todas as origens</option>':'<option value="">Sem origem definida</option>';
  return out+['auditoria','kaizen','avaliacao_processo','conversa','reuniao'].map(function(value){return'<option value="'+value+'">'+originLabels[value]+'</option>'}).join('')+(includeAll?'<option value="empty">Sem origem</option>':'');
}
function installSuggestionEnhancements(){
  var toolbar=document.querySelector('.suggestions-toolbar');
  if(toolbar&&!$('suggestions-origin-filter')){
    var origin=document.createElement('label');origin.className='suggestion-filter-wide';origin.innerHTML='FILTRAR POR ORIGEM<select id="suggestions-origin-filter">'+originOptions(true)+'</select>';origin.querySelector('select').addEventListener('change',window.renderImprovementSuggestions);toolbar.querySelector('button').insertAdjacentElement('beforebegin',origin);
    var person=document.createElement('label');person.className='suggestion-filter-wide';person.innerHTML='FILTRAR POR PESSOA<select id="suggestions-person-filter"><option value="all">Todas as pessoas</option></select>';person.querySelector('select').addEventListener('change',window.renderImprovementSuggestions);origin.insertAdjacentElement('afterend',person);
  }
  var formStatus=$('suggestion-status'),filterStatus=$('suggestions-status-filter');
  if(formStatus)formStatus.innerHTML=suggestionStatuses.map(function(status){return'<option>'+status+'</option>'}).join('');
  if(filterStatus){
    var selected=filterStatus.value;
    filterStatus.innerHTML='<option value="all">Todos os status</option>'+suggestionStatuses.map(function(status){return'<option>'+status+'</option>'}).join('');
    if(Array.from(filterStatus.options).some(function(option){return option.value===selected}))filterStatus.value=selected;
  }
  if(!$('suggestion-origin')){
    var label=document.createElement('label');label.innerHTML='ORIGEM DA SUGESTÃO<select id="suggestion-origin">'+originOptions(false)+'</select><small style="font-weight:500;color:#64748b">Ao vincular uma auditoria, a origem será preenchida automaticamente.</small>';
    $('suggestion-status').closest('label').insertAdjacentElement('beforebegin',label);
  }
}
function attachSuggestionAuditOrigin(){
  document.querySelectorAll('#suggestion-audits input[type=checkbox]').forEach(function(input){input.addEventListener('change',syncSuggestionOrigin)});
  syncSuggestionOrigin();
}
function syncSuggestionOrigin(){
  var hasAudit=app.selectedSuggestionValues('suggestion-audits',true).length>0,origin=$('suggestion-origin');
  if(!origin)return;
  if(hasAudit){origin.value='auditoria';origin.disabled=true}else origin.disabled=false;
}
var baseOpenSuggestion=window.openImprovementSuggestionForm;
window.openImprovementSuggestionForm=async function(id){
  installSuggestionEnhancements();
  await baseOpenSuggestion(id);
  var item=app.editingImprovementSuggestion;
  $('suggestion-origin').value=item&&item.origem||'';
  attachSuggestionAuditOrigin();
};
window.saveImprovementSuggestion=async function(){
  if(!await app.ensureAdmin())return;
  var title=$('suggestion-title').value.trim(),description=$('suggestion-description').value.trim(),sector=$('suggestion-sector').value,authors=app.selectedSuggestionValues('suggestion-authors',false),audits=app.selectedSuggestionValues('suggestion-audits',true);
  if(!title||!description||!sector){toast('⚠️ Preencha título, descrição e setor.');return}
  if(!authors.length){toast('⚠️ Selecione pelo menos um colaborador como autor.');return}
  var button=$('suggestion-save-button');button.disabled=true;button.textContent='Salvando...';
  try{
    await app.rpc('save_sugestao_melhoria_v3',{p_password:app.adminPassword,p_id:app.editingImprovementSuggestion?Number(app.editingImprovementSuggestion.id):null,p_titulo:title,p_descricao:description,p_setor:sector,p_origem:audits.length?'auditoria':$('suggestion-origin').value||null,p_autores:authors,p_auditoria_ids:audits,p_status:$('suggestion-status').value,p_observacao_status:$('suggestion-status-note').value.trim()});
    window.closeImprovementSuggestionForm();await window.loadImprovementSuggestions();toast('✅ Sugestão salva com a origem e os autores vinculados.');
  }catch(error){toast('❌ Não foi possível salvar: '+error.message)}
  finally{button.disabled=false;button.textContent='💾 Salvar sugestão'}
};
function suggestionStatusClass(status){
  return status==='Aguardando avaliação'?'pending-review':status==='Registrada'?'registered':status==='Em análise'?'analysis':status==='Aprovada'?'approved':status==='Em implementação'?'implementation':status==='Concluída'?'done':'rejected';
}
function refreshSuggestionPersonFilter(){
  var select=$('suggestions-person-filter');if(!select)return;
  var current=select.value,people={};
  app.improvementSuggestions.forEach(function(item){(item.autores||[]).forEach(function(author){people[author.origem+':'+author.origemId]=author.nome})});
  select.innerHTML='<option value="all">Todas as pessoas</option>'+Object.keys(people).sort(function(a,b){return people[a].localeCompare(people[b],'pt-BR')}).map(function(token){return'<option value="'+html(token)+'">'+html(people[token])+'</option>'}).join('');
  if(people[current])select.value=current;
}
window.evaluateKaizen=async function(id,approved){
  if(!await app.ensureAdmin())return;
  var note=prompt(approved?'Observação da Engenharia para registrar a ideia:':'Motivo da não aprovação (opcional):','');
  if(note===null)return;
  try{
    await app.rpc('avaliar_sugestao_kaizen',{p_password:app.adminPassword,p_id:Number(id),p_aprovada:!!approved,p_observacao:note.trim()});
    await window.loadImprovementSuggestions();toast(approved?'✅ Kaizen avaliado e alterado para Registrada.':'✅ Avaliação registrada como Não aprovada.');
  }catch(error){toast('❌ Não foi possível avaliar: '+error.message)}
};
window.renderImprovementSuggestions=function(){
  installSuggestionEnhancements();refreshSuggestionPersonFilter();
  var rows=app.improvementSuggestions.slice(),status=$('suggestions-status-filter').value,sector=$('suggestions-sector-filter').value,origin=$('suggestions-origin-filter').value,person=$('suggestions-person-filter').value;
  if(status!=='all')rows=rows.filter(function(item){return item.status===status});
  if(sector!=='all')rows=rows.filter(function(item){return item.setor===sector});
  if(origin!=='all')rows=rows.filter(function(item){return origin==='empty'?!item.origem:item.origem===origin});
  if(person!=='all')rows=rows.filter(function(item){return(item.autores||[]).some(function(author){return author.origem+':'+author.origemId===person})});
  $('suggestions-total').textContent=rows.length;$('suggestions-analysis').textContent=rows.filter(function(item){return item.status==='Em análise'||item.status==='Aguardando avaliação'}).length;
  $('suggestions-implementation').textContent=rows.filter(function(item){return item.status==='Em implementação'}).length;$('suggestions-done').textContent=rows.filter(function(item){return item.status==='Concluída'}).length;
  var target=$('suggestions-list');if(!rows.length){target.innerHTML='<div class="empty-state" style="grid-column:1/-1;background:#fff;border:1px solid #dbe3ea;border-radius:10px">Nenhuma sugestão encontrada para estes filtros.</div>';return}
  target.innerHTML=rows.map(function(item){
    var authors=(item.autores||[]).map(function(author){return'<span class="suggestion-badge">'+html(author.nome)+'</span>'}).join('');
    var audits=(item.auditorias||[]).map(function(audit){return'<span class="suggestion-badge audit">'+html(app.suggestionAuditLabel(audit))+'</span>'}).join('');
    var linked=(item.acoes||[]).map(function(action){return'<span class="suggestion-badge" style="background:#fef3c7;color:#92400e">5W2H #'+action.id+' • '+html(action.acao)+' • '+html(action.status)+'</span>'}).join('');
    var history=(item.historico||[]).map(function(event){return'<li><strong>'+html(event.status)+'</strong> • '+html(app.suggestionDate(event.data))+(event.observacao?'<br>'+html(event.observacao):'')+'</li>'}).join('');
    var pending=item.status==='Aguardando avaliação'&&item.origem==='kaizen';
    var actions='';
    if(activeAdmin()){
      if(pending)actions='<div class="suggestion-actions"><button class="engineering-approve" onclick="evaluateKaizen('+item.id+',true)">✓ Engenharia: registrar</button><button class="engineering-reject" onclick="evaluateKaizen('+item.id+',false)">✕ Não aprovar</button><button style="background:#fef3c7;color:#92400e" onclick="openImprovementSuggestionForm('+item.id+')">✏️ Revisar conteúdo</button></div>';
      else actions='<div class="suggestion-actions"><button style="background:#dbeafe;color:#1d4ed8" onclick="createActionPlanFromSuggestion('+item.id+')">'+((item.acoes||[]).length?'＋ Nova ação vinculada':'🧭 Transformar em ação')+'</button><button style="background:#fef3c7;color:#92400e" onclick="openImprovementSuggestionForm('+item.id+')">✏️ Editar / atualizar</button><button style="background:#fee2e2;color:#991b1b" onclick="deleteImprovementSuggestion('+item.id+')">✕ Remover</button></div>';
    }
    return'<article class="suggestion-card"><div class="suggestion-card-head"><h3>'+html(item.titulo)+'</h3><div class="suggestion-card-tags"><span class="suggestion-sector">'+html(app.suggestionSectorLabel(item.setor))+'</span><span class="origin-badge '+(item.origem||'empty')+'">'+html(originLabels[item.origem||'']||item.origem)+'</span><span class="suggestion-status '+suggestionStatusClass(item.status)+'">'+html(item.status)+'</span></div></div><div class="suggestion-description">'+html(item.descricao)+'</div>'+(pending?'<div class="suggestion-engineering-note">Aguardando avaliação da Engenharia. Somente após a aprovação esta ideia passará para “Registrada”.</div>':'')+'<span class="suggestion-label">IDEIA DE</span><div class="suggestion-badges">'+(authors||'<span class="suggestion-empty-link">Envio sem identificação</span>')+'</div><span class="suggestion-label">AUDITORIAS DE ORIGEM</span><div class="suggestion-badges">'+(audits||'<span class="suggestion-empty-link">Sem auditoria específica vinculada</span>')+'</div><span class="suggestion-label">AÇÕES NO PLANO 5W2H</span><div class="suggestion-badges">'+(linked||'<span class="suggestion-empty-link">Ainda não virou ação</span>')+'</div><details class="suggestion-timeline"><summary>Acompanhamento de status • atualizado em '+html(app.suggestionDate(item.updated_at))+'</summary><ul>'+history+'</ul></details>'+actions+'</article>';
  }).join('');
};

/* ------------------------------------------------------------------------ */
/* Página pública de Kaizen e cartaz A4 com QR Code.                         */
/* ------------------------------------------------------------------------ */

function installKaizenTab(){
  if($('kaizen-tab-btn'))return;
  var button=document.createElement('button');button.id='kaizen-tab-btn';button.className='tab-btn';button.textContent='💡 Enviar Kaizen';button.onclick=window.switchKaizenTab;
  var dashboardButton=Array.from(document.querySelectorAll('.tab-bar .tab-btn')).find(function(item){return(item.getAttribute('onclick')||'').indexOf("switchTab('dashboard')")>=0});
  if(dashboardButton)dashboardButton.insertAdjacentElement('afterend',button);else document.querySelector('.tab-bar').appendChild(button);
  var tab=document.createElement('div');tab.id='tab-kaizen';tab.className='tab-content';
  tab.innerHTML='<div class="page-header"><div class="logo">ALCOB<small>ecovergalhão ♻</small></div><div class="page-title">Kaizen — Sugestões da Fábrica</div><div class="meta-box"><span class="legend-item leg-green">Acesso livre</span><span class="legend-item leg-blue">Avaliação pela Engenharia</span></div></div><div class="kaizen-wrap"><div class="kaizen-intro"><section class="kaizen-card"><h2>Sua ideia pode melhorar nosso processo</h2><p>Registre uma oportunidade de segurança, qualidade, produtividade, organização ou redução de desperdícios. A Engenharia avaliará a proposta antes de ela entrar no acompanhamento oficial.</p><div class="kaizen-flow"><span>1. Envie a ideia</span><span>2. Engenharia avalia</span><span>3. Ideia registrada</span></div></section><section class="kaizen-card kaizen-qr-card"><h3>Acesso rápido na fábrica</h3><img src="assets/kaizen-sugestoes-qr.png" alt="QR Code para registrar uma sugestão Kaizen"><p>Aponte a câmera do celular.</p><button class="btn btn-print" onclick="printKaizenPoster()">🖨️ Imprimir cartaz A4</button></section></div><form class="kaizen-form" onsubmit="submitPublicKaizen(event)"><label class="wide">TÍTULO DA IDEIA *<input id="kaizen-title" maxlength="180" required placeholder="Resuma sua sugestão"></label><label class="wide">DESCRIÇÃO *<textarea id="kaizen-description" maxlength="5000" required placeholder="Explique a situação atual, a ideia e o benefício esperado"></textarea></label><label>SETOR ONDE SERÁ IMPLEMENTADA — OPCIONAL<select id="kaizen-sector"><option value="">Não informar / a definir</option>'+app.actionSelectOptions('')+'</select></label><label>ORIGEM E STATUS<input value="Kaizen • Aguardando avaliação da Engenharia" disabled></label><details class="kaizen-people-details wide"><summary><span>IDENTIFICAR DE QUEM SURGIU A IDEIA — OPCIONAL</span><small id="kaizen-author-count">Sem identificação</small></summary><div class="kaizen-people-content"><p>Se desejar, pesquise e selecione até cinco colaboradores. Você também pode enviar anonimamente.</p><div class="suggestion-search-row"><input id="kaizen-author-search" type="search" autocomplete="off" placeholder="Pesquisar por nome, cargo ou setor..."><span class="suggestion-search-count" id="kaizen-author-result-count"></span></div><div class="suggestion-picker" id="kaizen-authors"></div></div></details><div id="kaizen-success" class="kaizen-success enhancement-hidden"></div><div class="kaizen-form-actions"><span>Nenhuma senha, identificação pessoal ou setor é obrigatório para enviar.</span><button class="btn btn-save" id="kaizen-submit" type="submit">💾 Enviar sugestão para a Engenharia</button></div></form></div>';
  document.body.appendChild(tab);
  $('kaizen-author-search').addEventListener('input',filterKaizenAuthors);
  var poster=document.createElement('div');poster.className='kaizen-poster-shell';poster.innerHTML='<article class="kaizen-poster"><header class="kaizen-poster-brand"><strong>ALCOB</strong><small>ecovergalhão ♻</small></header><h1>Tem uma ideia de melhoria?</h1><p>Ajude a tornar nosso trabalho mais seguro, organizado, produtivo e com menos desperdícios.</p><img src="assets/kaizen-sugestoes-qr.png" alt="QR Code Kaizen"><p><strong>Aponte a câmera do celular e registre sua sugestão.</strong></p><div class="kaizen-poster-steps"><div>1<br>Escaneie</div><div>2<br>Descreva</div><div>3<br>Envie</div></div><footer>A sugestão será avaliada pela Engenharia antes de entrar no acompanhamento oficial.</footer></article>';
  document.body.appendChild(poster);
}
function renderKaizenAuthors(){
  var people=app.registeredPeople(),target=$('kaizen-authors');
  target.innerHTML=people.length?people.map(function(person){return'<label data-suggestion-option="kaizen-author"><input type="checkbox" value="'+html(person.token)+'"><span><strong>'+html(person.nome)+'</strong><small>'+html(person.cargo+(person.setor?' • '+sectorLabel(person.setor):''))+'</small></span></label>'}).join(''):'<div class="empty-state">Nenhum colaborador cadastrado. A ideia ainda pode ser enviada anonimamente.</div>';
  target.querySelectorAll('input').forEach(function(input){input.addEventListener('change',function(){
    var selected=target.querySelectorAll('input:checked');
    if(selected.length>5){input.checked=false;toast('⚠️ É possível identificar no máximo cinco colaboradores.')}
    filterKaizenAuthors();
  })});
  filterKaizenAuthors();
}
function filterKaizenAuthors(){
  var options=Array.from(document.querySelectorAll('#kaizen-authors label[data-suggestion-option]')),query=key($('kaizen-author-search')&&$('kaizen-author-search').value),visible=0,selected=document.querySelectorAll('#kaizen-authors input:checked').length;
  options.forEach(function(label){var show=!query||key(label.textContent).indexOf(query)>=0;label.style.display=show?'':'none';if(show)visible++});
  if($('kaizen-author-count'))$('kaizen-author-count').textContent=selected?selected+' selecionado(s)':'Sem identificação';
  if($('kaizen-author-result-count'))$('kaizen-author-result-count').textContent=visible+' de '+options.length+' exibido(s)';
}
window.switchKaizenTab=async function(){
  installKaizenTab();selectAllTabs('tab-kaizen','kaizen-tab-btn');
  await app.loadSubordinations();renderKaizenAuthors();
  if(location.hash!=='#kaizen')history.replaceState(null,'','#kaizen');
};
window.submitPublicKaizen=async function(event){
  event.preventDefault();
  var authors=Array.from(document.querySelectorAll('#kaizen-authors input:checked')).map(function(input){return input.value});
  if(authors.length>5){toast('⚠️ Selecione no máximo cinco colaboradores.');return}
  var button=$('kaizen-submit');button.disabled=true;button.textContent='Enviando...';
  try{
    var id=await app.rpc('enviar_sugestao_kaizen',{p_titulo:$('kaizen-title').value.trim(),p_descricao:$('kaizen-description').value.trim(),p_setor:$('kaizen-sector').value,p_autores:authors});
    event.target.reset();var peopleDetails=document.querySelector('.kaizen-people-details');if(peopleDetails)peopleDetails.open=false;renderKaizenAuthors();
    $('kaizen-success').classList.remove('enhancement-hidden');$('kaizen-success').textContent='✅ Sugestão #'+id+' enviada. Ela está aguardando avaliação da Engenharia.';
    toast('✅ Kaizen enviado para avaliação da Engenharia.');
  }catch(error){toast('❌ Não foi possível enviar: '+error.message)}
  finally{button.disabled=false;button.textContent='💾 Enviar sugestão para a Engenharia'}
};
window.printKaizenPoster=function(){document.body.classList.add('kaizen-printing');window.print();setTimeout(function(){document.body.classList.remove('kaizen-printing')},800)};
window.addEventListener('afterprint',function(){document.body.classList.remove('kaizen-printing')});

/* ------------------------------------------------------------------------ */
/* Auditoria operacional integrada às abas de Forno, Prensa e Laminação.    */
/* ------------------------------------------------------------------------ */

var laminationActivities={
  roda:[
    'Aciona a bomba de água da roda, identifica presença de ar e executa corretamente a retirada do ar?',
    'Localiza e liga corretamente o acetileno da roda e da fita?',
    'Instala o batoque da panela e confere seu alinhamento?',
    'Confere a condição da tocha de aquecimento do bico e sabe regulá-la?',
    'Explica a função da solenoide e do compressor no sistema de ar?',
    'Localiza os bicos aspersores e executa registros, bomba, desobstrução, mangueiras e alinhamento para garantir eficiência?',
    'Aciona e verifica o pistão da fita utilizando corretamente manivela e volante?',
    'Manuseia a roda tensora com o macaco hidráulico de forma segura?',
    'Localiza no sensor/display a temperatura da água da roda e interpreta o valor?',
    'Posiciona e liga corretamente o aftercooler?',
    'Realiza corretamente a passagem de vareta no bico da panela?',
    'Posiciona e regula o maçarico de aquecimento do bico?',
    'Liga e regula corretamente a tocha da fita?',
    'Executa corretamente o fechamento do dreno da panela?',
    'Liga ou desliga a torre de resfriamento para manter a água entre 28 °C e 30 °C?'
  ],
  laminacao:[
    'Preenche corretamente o checklist operacional?','Executa o ajuste do endireitador?','Executa o ajuste do rebarbador e da faca?','Liga e desliga os motores na sequência correta?','Realiza a passagem de barra para aquecimento?','Retira o ar do sistema?','Ajusta a velocidade conforme o processo?','Executa o ajuste dos cilindros?','Realiza a passagem de barra no laminador?','Executa e registra o controle térmico?','Realiza a retirada de amostras?','Conhece as ações aplicáveis em falhas de produção?','Executa as limpezas operacionais previstas?','Executa as manutenções de produção autorizadas?','Presta auxílio mecânico conforme orientação?','Preenche os relatórios do processo?','Realiza a passagem de barra pelo painel?'
  ],
  bobinador:[
    'Confere o painel de acionamento do bobinador?','Confere o óleo da roldana?','Abre os dois registros de ar do cano proveniente da decapagem?','Verifica se o purgador aplica cera no vergalhão?','Configura abertura e fechamento da amarração, avaliando o parâmetro de referência de 96%?','Liga/desliga o automático da amarração e avalia a quantidade de voltas de referência?','Executa a transposição de gaiolas?','Realiza a retirada de amostras?','Identifica defeitos, suas causas e as ações aplicáveis ao vergalhão?','Preenche o formulário de defeitos na folha de processo?','Executa limpeza e organização e preenche o formulário correspondente?','Segue o fluxo de comunicação com o laboratório?','Opera a prensa do jumbo?','Embala o jumbo envolvendo-o com plástico?','Passa a cinta e coloca o grampo?','Prensa utilizando a bobina pneumática?','Realiza pesagem e emite etiqueta com peso total e líquido?','Registra o peso no caderno ou folha de processo?','Troca as cintas quando o rolo termina?','Pesa o palete antes do setup e avalia sua condição de uso?'
  ]
};
var operationalActivities={
  forno:[
    'Identifica a sequência correta de carregamento e confere os materiais antes de adicioná-los ao forno?',
    'Conhece os critérios de peso, identificação e rastreabilidade da carga?',
    'Executa o carregamento sem introduzir material úmido, fechado ou contaminado?',
    'Monitora temperatura, condição do banho e sinais de anormalidade durante o processo?',
    'Conhece a sequência, a finalidade e os cuidados do tratamento do metal?',
    'Realiza a retirada de escória conforme o padrão e dá a destinação correta?',
    'Confere panela, bico, calha e dispositivos antes de iniciar a vazão?',
    'Executa a vazão mantendo controle de temperatura, fluxo e segurança?',
    'Reconhece desvios de composição, temperatura, vazamento ou obstrução e sabe como agir?',
    'Preenche os registros do processo e mantém a rastreabilidade do lote?',
    'Comunica-se com Laboratório, Laminação e liderança nos momentos definidos?',
    'Conhece os limites de sua atuação e quando deve interromper o processo e solicitar apoio?'
  ],
  prensa:[
    'Identifica e separa corretamente os tipos de sucata antes da prensagem?',
    'Reconhece materiais proibidos, fechados, úmidos ou contaminados e impede seu processamento?',
    'Confere peso, identificação e rastreabilidade do material recebido?',
    'Realiza a inspeção pré-operacional da prensa e de seus dispositivos de segurança?',
    'Carrega a prensa respeitando capacidade, distribuição e zona segura?',
    'Opera o ciclo de prensagem na sequência correta e sem improvisações?',
    'Inspeciona vazamentos, mangueiras, conexões e condição hidráulica antes e durante a operação?',
    'Confere dimensões, compactação e integridade do bloco prensado?',
    'Identifica e registra blocos, lotes e destinos conforme o padrão?',
    'Realiza movimentação e armazenamento dos blocos com segurança?',
    'Reconhece travamentos, ruídos, perda de pressão e outras anormalidades e sabe como agir?',
    'Preenche checklist, produção, perdas e ocorrências do turno?'
  ]
};
var safetyQuestions=[
  'Usa corretamente todos os EPIs obrigatórios da atividade?',
  'Identifica os principais riscos da tarefa e descreve as barreiras de prevenção?',
  'Conhece e aplica parada de emergência, bloqueio e liberação de energia quando aplicável?',
  'Mantém distância segura de partes móveis, metal líquido, cargas e áreas de risco?',
  'Interrompe a atividade e comunica imediatamente condição insegura, quase acidente ou desvio crítico?',
  'Participa dos DDS e conhece o procedimento de emergência do setor?'
];
var fiveSQuestions=[
  'Mantém ferramentas, materiais e acessórios nos locais definidos e identificados?',
  'Mantém piso, corredores, acessos e saídas de emergência limpos e desobstruídos?',
  'Segrega resíduos e materiais não conformes nos recipientes ou áreas corretas?',
  'Executa a rotina de limpeza do equipamento e do posto ao final da atividade?',
  'Preserva o padrão de organização e registra oportunidades de melhoria 5S?'
];
function qParam(group){return group==='Processo'?'Demonstrar conhecimento e execução conforme instrução de trabalho, padrão operacional e parâmetros vigentes.':group==='Segurança'?'Conforme procedimento de Segurança do Trabalho, matriz de EPIs e DDS vigente.':'Conforme padrão 5S e gestão à vista do setor.'}
function operatorQuestionSet(sector,subsetor){
  var technical=sector==='laminacao'?laminationActivities[subsetor]||[]:operationalActivities[sector]||[];
  var rows=[];technical.forEach(function(question,index){rows.push({id:'processo-'+(index+1),group:'Processo',question:question,parameter:qParam('Processo')})});
  safetyQuestions.forEach(function(question,index){rows.push({id:'seguranca-'+(index+1),group:'Segurança',question:question,parameter:qParam('Segurança')})});
  fiveSQuestions.forEach(function(question,index){rows.push({id:'5s-'+(index+1),group:'5S',question:question,parameter:qParam('5S')})});
  return rows;
}
var integratedOperatorForms={};
function operatorPerson(form){
  var name=form.name.value;
  return app.subordinations.find(function(item){return item.setor===form.type&&key(item.subordinado)===key(name)})||null;
}
function operatorSubsetor(form,person){return form.type==='laminacao'&&person?person.subsetor||'laminacao':null}
function operatorScoreClass(score){return score>95?'nota-verde':score>=70?'nota-azul':score>=50?'nota-amarelo':'nota-vermelho'}
function calculateIntegratedOperatorScore(form){
  var earned=0,total=0;
  form.body.querySelectorAll('tr[data-operator-id]').forEach(function(row){
    var value=row.querySelector('.operator-status').value;row.classList.remove('operator-ok','operator-no');
    if(value==='ok'){earned+=1;total+=1;row.classList.add('operator-ok')}
    else if(value==='partial'){earned+=.5;total+=1;row.classList.add('operator-no')}
    else if(value==='no'){total+=1;row.classList.add('operator-no')}
  });
  var score=total?earned/total*100:0,note=$(form.config.pfx+'-nota');
  if(note){note.textContent=score.toFixed(2).replace('.',',')+'%';note.classList.remove('nota-verde','nota-azul','nota-amarelo','nota-vermelho');note.classList.add(operatorScoreClass(score))}
  return score;
}
function renderIntegratedOperatorQuestions(form,savedItems,person){
  person=person||operatorPerson(form);
  var subsetor=operatorSubsetor(form,person),saved={};
  (savedItems||[]).forEach(function(item){saved[item.id]=item});
  form.title.textContent='Auditoria operacional — '+sectorLabel(form.type)+(subsetor?' / '+(subsetLabels[subsetor]||subsetor):'');
  form.subtitle.textContent=person?(subsetor?'Subsetor do cadastro: '+(subsetLabels[subsetor]||subsetor):'Atividades operacionais do setor'):'Selecione um colaborador operacional cadastrado para carregar o formulário.';
  if(!person){
    form.body.innerHTML='<tr><td colspan="6" class="integrated-operator-empty">Selecione o nível “Operacional” e informe um colaborador cadastrado neste setor.</td></tr>';
    calculateIntegratedOperatorScore(form);return;
  }
  var rows=operatorQuestionSet(form.type,subsetor),lastGroup='';
  form.body.innerHTML=rows.map(function(item,index){
    var group=item.group!==lastGroup?'<tr class="group-row"><td colspan="6">'+html(item.group)+'</td></tr>':'';lastGroup=item.group;
    var prior=saved[item.id]||{},value=prior.status==='OK'?'ok':prior.status==='Parcial'?'partial':prior.status==='NÃO'?'no':prior.status==='Não se aplica'?'na':'';
    return group+'<tr data-operator-id="'+item.id+'"><td>'+(index+1)+'</td><td>'+html(item.group)+'</td><td>'+html(item.question)+'</td><td><select class="operator-status"><option value="">Selecione</option><option value="ok"'+(value==='ok'?' selected':'')+'>Conforme</option><option value="partial"'+(value==='partial'?' selected':'')+'>Parcial</option><option value="no"'+(value==='no'?' selected':'')+'>Não conforme</option><option value="na"'+(value==='na'?' selected':'')+'>Não se aplica</option></select></td><td><input class="operator-note" maxlength="500" value="'+html(prior.motivo||'')+'" placeholder="Obrigatório para parcial/não conforme"></td><td>'+html(item.parameter)+'</td></tr>';
  }).join('');
  form.body.querySelectorAll('.operator-status').forEach(function(select){select.addEventListener('change',function(){calculateIntegratedOperatorScore(form)})});
  calculateIntegratedOperatorScore(form);
}
function syncIntegratedOperatorForm(form,force){
  var operational=form.role.value==='subordinado',person=operatorPerson(form),personId=person?String(person.id)+'|'+String(operatorSubsetor(form,person)||''):'';
  form.supervisorTable.style.display=operational?'none':'';
  form.panel.classList.toggle('enhancement-hidden',!operational);
  form.header.textContent=operational?'Formulário de Auditoria Operacional — '+sectorLabel(form.type):form.baseHeader;
  if(!operational){
    form.saveButton.onclick=form.baseSave;form.clearButton.onclick=form.baseClear;form.printButton.onclick=form.basePrint;
    form.currentPersonId='';
    return;
  }
  form.saveButton.onclick=function(event){event.preventDefault();saveIntegratedOperatorAudit(form.type)};
  form.clearButton.onclick=function(event){event.preventDefault();clearIntegratedOperatorAudit(form.type)};
  form.printButton.onclick=function(event){event.preventDefault();window.print()};
  form.panel.classList.toggle('operator-panel-locked',!person);
  if(force||form.currentPersonId!==personId){form.currentPersonId=personId;renderIntegratedOperatorQuestions(form,null,person)}
  form.panel.querySelectorAll('select,input').forEach(function(field){field.disabled=!person});
}
function installIntegratedOperatorForms(){
  ['forno','laminacao','prensa'].forEach(function(type){
    var config=app.types[type],sheet=config&&$(config.sheet),role=config&&$(config.pfx+'-audited-role');
    if(!sheet||!role||integratedOperatorForms[type])return;
    var operatorOption=Array.from(role.options).find(function(option){return option.value==='subordinado'});if(operatorOption)operatorOption.textContent='Operacional / subordinado';
    var supervisorTable=sheet.querySelector('table.audit-table'),actions=sheet.querySelector('.form-actions'),saveButton=actions&&actions.querySelector('.btn-save'),clearButton=actions&&actions.querySelector('.btn-clear'),printButton=actions&&actions.querySelector('.btn-print'),header=sheet.querySelector('.fh-title'),name=$(config.pfx+'-nome');
    if(!supervisorTable||!saveButton||!clearButton||!printButton||!header||!name)return;
    supervisorTable.classList.add('supervisor-audit-table');
    var panel=document.createElement('section');panel.id=config.pfx+'-operator-panel';panel.className='integrated-operator-panel enhancement-hidden';
    panel.innerHTML='<header class="integrated-operator-head"><div><h3 id="'+config.pfx+'-operator-title">Auditoria operacional — '+html(sectorLabel(type))+'</h3><p id="'+config.pfx+'-operator-subtitle">Selecione um colaborador operacional cadastrado para carregar o formulário.</p></div><span>Conhecimento técnico • Segurança • 5S</span></header><div class="operator-table-wrap"><table class="operator-table"><thead><tr><th style="width:48px">#</th><th style="width:82px">Grupo</th><th>Conhecimento / execução avaliada</th><th class="status-cell">Resultado</th><th class="note-cell">Apontamento / evidência</th><th>Parâmetro</th></tr></thead><tbody id="'+config.pfx+'-operator-body"></tbody></table></div>';
    supervisorTable.insertAdjacentElement('beforebegin',panel);
    var form={type:type,config:config,sheet:sheet,role:role,name:name,header:header,baseHeader:header.textContent,supervisorTable:supervisorTable,panel:panel,title:$(config.pfx+'-operator-title'),subtitle:$(config.pfx+'-operator-subtitle'),body:$(config.pfx+'-operator-body'),saveButton:saveButton,clearButton:clearButton,printButton:printButton,baseSave:saveButton.onclick,baseClear:clearButton.onclick,basePrint:printButton.onclick,currentPersonId:''};
    integratedOperatorForms[type]=form;
    role.addEventListener('change',function(){editingOperatorAudit=null;if(app.clearAuditEditing)app.clearAuditEditing();syncIntegratedOperatorForm(form,true)});
    name.addEventListener('input',function(){if(editingOperatorAudit&&editingOperatorAudit.type===type&&key(editingOperatorAudit.team)!==key(name.value)){editingOperatorAudit=null;var notice=$('editAuditNotice');if(notice)notice.remove()}syncIntegratedOperatorForm(form)});
    syncIntegratedOperatorForm(form,true);
  });
}
function integratedOperatorReportItems(form,person){
  var subsetor=operatorSubsetor(form,person),questions=operatorQuestionSet(form.type,subsetor),map={};questions.forEach(function(item){map[item.id]=item});
  return Array.from(form.body.querySelectorAll('tr[data-operator-id]')).map(function(row,index){
    var config=map[row.dataset.operatorId],value=row.querySelector('.operator-status').value,status=value==='ok'?'OK':value==='partial'?'Parcial':value==='no'?'NÃO':value==='na'?'Não se aplica':'Não avaliado';
    return{id:row.dataset.operatorId,group:config.group,num:String(index+1),question:config.question,value:value==='partial'?'0,5':value==='na'?'N/A':'1',parameter:config.parameter,status:status,motivo:row.querySelector('.operator-note').value.trim()};
  });
}
function integratedOperatorPdf(form,record){
  if(typeof html2pdf!=='function')return;
  var copy=form.sheet.cloneNode(true);copy.style.cssText='position:fixed;left:-20000px;top:0;width:1150px;background:#fff;z-index:-1';
  copy.querySelectorAll('.form-actions,.audit-context-row,.supervisor-audit-table').forEach(function(item){item.remove()});
  var metadata='<div class="integrated-operator-pdf-meta"><div><b>Auditado</b><br>'+html(record.team)+'</div><div><b>Setor</b><br>'+html(sectorLabel(record.type))+'</div><div><b>Subsetor</b><br>'+html(subsetLabels[record.subsetor]||'—')+'</div><div><b>Auditor</b><br>'+html(record.report.auditorName)+'</div><div><b>Data / Nota</b><br>'+html(record.date)+' • '+record.score.toFixed(2).replace('.',',')+'%</div></div>';
  var formHeader=copy.querySelector('.form-header');if(formHeader)formHeader.insertAdjacentHTML('afterend',metadata);else copy.insertAdjacentHTML('afterbegin',metadata);
  copy.querySelectorAll('select').forEach(function(select){var span=document.createElement('span');span.textContent=select.options[select.selectedIndex]&&select.options[select.selectedIndex].textContent||'—';select.replaceWith(span)});
  copy.querySelectorAll('input,textarea').forEach(function(input){var span=document.createElement('span');span.textContent=input.value||'—';input.replaceWith(span)});
  document.body.appendChild(copy);
  html2pdf().set({margin:[5,5,5,5],filename:'Auditoria_Operacional_'+record.type+'_'+record.team.replace(/\s+/g,'_')+'_'+record.date+'.pdf',image:{type:'jpeg',quality:.98},html2canvas:{scale:2},jsPDF:{unit:'mm',format:'a4',orientation:'landscape'}}).from(copy).save().then(function(){copy.remove()},function(){copy.remove();toast('⚠️ Auditoria salva, mas o PDF não foi gerado.')});
}
async function saveIntegratedOperatorAudit(type){
  if(!await app.ensureAdmin())return;
  var form=integratedOperatorForms[type],person=form&&operatorPerson(form),auditorField=$(form.config.pfx+'-sig1'),auditor=app.auditors.find(function(item){return auditorField&&String(item.id)===String(auditorField.value)});
  if(!person){toast('⚠️ Selecione um colaborador operacional cadastrado neste setor.');return}
  if(!auditor){toast('⚠️ Selecione um auditor cadastrado no sistema.');return}
  var items=integratedOperatorReportItems(form,person),missing=items.some(function(item){return item.status==='Não avaliado'}),missingNote=items.some(function(item){return(item.status==='Parcial'||item.status==='NÃO')&&!item.motivo});
  if(missing){toast('⚠️ Avalie todos os itens ou marque “Não se aplica”.');return}
  if(missingNote){toast('⚠️ Registre o apontamento nos itens parciais ou não conformes.');return}
  var date=$(form.config.pfx+'-data').value;if(!date){toast('⚠️ Informe a data da auditoria.');return}
  var score=calculateIntegratedOperatorScore(form),subsetor=operatorSubsetor(form,person),report={savedAt:new Date().toISOString(),items:items,auditorName:auditor.nome,auditedRole:'subordinado',supervisorName:person.supervisor||'',subsetor:subsetor,operatorAudit:true};
  var record={id:editingOperatorAudit&&editingOperatorAudit.type===type?Number(editingOperatorAudit.id):Date.now(),type:type,team:person.subordinado,date:date,cargo:person.cargo,score:+score.toFixed(2),totalOk:items.filter(function(item){return item.status==='OK'}).length,totalNo:items.filter(function(item){return item.status==='NÃO'||item.status==='Parcial'}).length,supervisorName:person.supervisor||'',auditedRole:'subordinado',subsetor:subsetor,report:report};
  var button=form.saveButton,originalText=button.textContent;button.disabled=true;button.textContent='Salvando...';
  try{
    await app.rpc('save_auditoria',{p_password:app.adminPassword,p_audit_id:record.id,p_type:record.type,p_team:record.team,p_audit_date:record.date,p_cargo:record.cargo,p_score:record.score,p_total_ok:record.totalOk,p_total_no:record.totalNo,p_report:record.report,p_supervisor_name:record.supervisorName||null,p_audited_role:'subordinado',p_subsetor:record.subsetor});
    var saved=app.allSaved(),index=saved.findIndex(function(item){return Number(item.id)===record.id});if(index>=0)saved[index]=record;else saved.push(record);app.setLocal(saved);
    integratedOperatorPdf(form,record);clearIntegratedOperatorAudit(type);renderSaved('all');if(window.rebuildAuditDashboard)window.rebuildAuditDashboard();window.refreshDash();toast(record.supervisorName?'✅ Auditoria operacional salva e vinculada a '+record.supervisorName+'.':'✅ Auditoria operacional salva para o colaborador cadastrado.');
  }catch(error){toast('❌ Não foi possível salvar: '+error.message)}
  finally{button.disabled=false;button.textContent=originalText}
}
function clearIntegratedOperatorAudit(type){
  var form=integratedOperatorForms[type];if(!form)return;
  editingOperatorAudit=null;var notice=$('editAuditNotice');if(notice)notice.remove();
  form.name.value='';var auditor=$(form.config.pfx+'-sig1'),audited=$(form.config.pfx+'-sig2'),cargo=$(form.config.pfx+'-cargo'),date=$(form.config.pfx+'-data');if(auditor)auditor.value='';if(audited)audited.value='';if(cargo)cargo.value='';if(date)date.value=new Date().toISOString().slice(0,10);
  form.currentPersonId='';form.name.dispatchEvent(new Event('input',{bubbles:true}));syncIntegratedOperatorForm(form,true);
}
var baseEditSavedAudit=window.editSavedAudit;
window.editSavedAudit=async function(id){
  if(!await app.ensureAdmin())return;
  var audit=app.allSaved().find(function(item){return Number(item.id)===Number(id)});
  if(!(audit&&audit.report&&audit.report.operatorAudit)){
    var standardForm=audit&&integratedOperatorForms[audit.type];if(standardForm){standardForm.role.value='supervisor';syncIntegratedOperatorForm(standardForm,true)}
    return baseEditSavedAudit(id);
  }
  var form=integratedOperatorForms[audit.type];if(!form){toast('⚠️ Formulário operacional não encontrado para este setor.');return}
  await Promise.all([app.loadSubordinations(),app.loadAuditors()]);
  form.role.value='subordinado';form.name.value=audit.team;form.role.dispatchEvent(new Event('change',{bubbles:true}));form.name.dispatchEvent(new Event('input',{bubbles:true}));
  editingOperatorAudit=audit;
  var person=operatorPerson(form),auditor=app.auditors.find(function(item){return key(item.nome)===key(audit.report.auditorName)}),auditorField=$(form.config.pfx+'-sig1');
  $(form.config.pfx+'-data').value=audit.date;$(form.config.pfx+'-cargo').value=audit.cargo;if(auditorField)auditorField.value=auditor?String(auditor.id):'';
  form.currentPersonId=person?String(person.id)+'|'+String(operatorSubsetor(form,person)||''):'';renderIntegratedOperatorQuestions(form,audit.report.items,person);syncIntegratedOperatorForm(form);
  selectAllTabs(form.config.tab);var tabButton=Array.from(document.querySelectorAll('.tab-bar .tab-btn')).find(function(item){var code=item.getAttribute('onclick')||'';return item.id==='press-tab-btn'&&audit.type==='prensa'||code.indexOf("switchTab('"+audit.type+"')")>=0});if(tabButton)tabButton.classList.add('active');
  var oldNotice=$('editAuditNotice');if(oldNotice)oldNotice.remove();var note=document.createElement('div');note.id='editAuditNotice';note.className='operator-edit-notice';note.textContent='✏️ Editando auditoria operacional salva. Ao salvar, este registro será atualizado.';form.panel.insertAdjacentElement('beforebegin',note);
  toast('✏️ Auditoria operacional aberta na aba de '+sectorLabel(audit.type)+'.');
};
var baseViewSavedReport=window.viewSavedReport;
window.viewSavedReport=async function(id){
  await baseViewSavedReport(id);
  var audit=app.allSaved().find(function(item){return Number(item.id)===Number(id)}),meta=document.querySelector('#savedReportModal .report-meta');
  if(audit&&audit.report&&audit.report.operatorAudit&&meta){
    meta.insertAdjacentHTML('beforeend','<div><strong>FORMULÁRIO</strong>Auditoria operacional</div><div><strong>SUBSETOR</strong>'+html(subsetLabels[audit.subsetor||audit.report.subsetor]||'Não se aplica')+'</div>');
  }
};

/* ------------------------------------------------------------------------ */
/* Navegação e inicialização.                                                */
/* ------------------------------------------------------------------------ */

function syncEnhancedNavigation(){
  var admin=activeAdmin();
  if($('kaizen-tab-btn'))$('kaizen-tab-btn').style.display='';
  if($('action-status-filter'))$('action-status-filter').closest('label').style.display=admin?'':'none';
}
installHierarchySubsetor();installMatrixSubsetor();installActionEnhancements();installSuggestionEnhancements();installKaizenTab();installIntegratedOperatorForms();
decorateSubordinationTable();syncEnhancedNavigation();
var access=$('admin-access-btn');if(access)new MutationObserver(function(){setTimeout(function(){syncEnhancedNavigation();Object.keys(integratedOperatorForms).forEach(function(type){syncIntegratedOperatorForm(integratedOperatorForms[type])})},0)}).observe(access,{childList:true,characterData:true,subtree:true});
if(location.hash==='#kaizen')setTimeout(window.switchKaizenTab,100);
window.addEventListener('hashchange',function(){if(location.hash==='#kaizen')window.switchKaizenTab()});
setTimeout(function(){refreshPublicAudits();renderQualityChart();syncEnhancedNavigation()},700);
})();
