import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { picker, fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';
import { RadarApi } from '../service/RadarApi';
import {
  Candidate, Change, ConfirmInput, EditInput, Evaluation, EvaluationCase, Evidence, ExtractedTask,
  Health, Interval, MaterialInput, ParseResult, PlanInput, PlanResult, Slot, Source, Task, Unassigned
} from '../model/Types';

const INK: string = '#202B47';
const BLUE: string = '#3549B8';
const MUTED: string = '#66718A';
const BG: string = '#F5F6FA';

@Entry
@Component
struct Index {
  @State tab: number = 0;
  @State tasks: Task[] = [];
  @State candidates: Candidate[] = [];
  @State plan: PlanResult = { slots: [], unassigned: [], conflicts: 0 };
  @State evaluation: Evaluation | null = null;
  @State busy: boolean = false;
  @State status: string = '正在连接课业服务';
  @State online: boolean = false;
  @State settings: boolean = false;
  @State endpoint: string = 'http://127.0.0.1:8000';
  @State notice: string = '';
  @State published: string = '';
  @State availableStart: string = '19:00';
  @State availableEnd: string = '22:00';
  @State blockedText: string = '';
  @State editing: boolean = false;
  @State editCandidateId: string = '';
  @State editTaskId: string = '';
  @State editCourse: string = '';
  @State editTitle: string = '';
  @State editDue: string = '';
  @State editSubmission: string = '';
  @State editRequirements: string = '';
  @State editMinutes: string = '120';
  @State editTarget: string = '';
  @State editVersion: number | null = null;
  @State editEvidence: Evidence[] = [];
  @State editWarnings: string[] = [];
  @State editChanges: Change[] = [];
  @State source: Source | null = null;
  @State sourceEvidence: Evidence[] = [];
  @State historyText: string = '';
  private api: RadarApi = new RadarApi();
  private prefs: preferences.Preferences | null = null;

  aboutToAppear(): void { this.initialize(); }

  async initialize(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const localPrefs = await preferences.getPreferences(context, { name: 'youke_radar' });
      this.prefs = localPrefs;
      this.endpoint = (await localPrefs.get('endpoint', this.endpoint)) as string;
      this.api.baseUrl = this.endpoint;
      const cached = (await localPrefs.get('tasks', '[]')) as string;
      this.tasks = JSON.parse(cached) as Task[];
      this.plan = JSON.parse((await localPrefs.get('plan', JSON.stringify(this.plan))) as string) as PlanResult;
      this.availableStart = (await localPrefs.get('availableStart', '19:00')) as string;
      this.availableEnd = (await localPrefs.get('availableEnd', '22:00')) as string;
      this.blockedText = (await localPrefs.get('blockedText', '')) as string;
    } catch (_) { this.status = '本地缓存无法读取，尝试连接服务'; }
    await this.refresh();
  }

  async refresh(): Promise<void> {
    this.busy = true;
    try {
      this.api.baseUrl = this.endpoint.trim();
      const health = await this.api.request<Health>('/health');
      const tasks = await this.api.request<Task[]>('/tasks');
      const candidates = await this.api.request<Candidate[]>('/candidates');
      const plan = await this.api.request<PlanResult>('/plan');
      this.tasks = tasks;
      this.candidates = candidates;
      this.plan = plan;
      this.online = true;
      this.status = health.model_configured ? '已连接 · 上传通知即可开始' : '已连接 · 请先在电脑配置模型服务';
      try { await this.cache(); }
      catch (_) { this.status = '已连接，但本地缓存保存失败；离线时可能显示旧数据'; }
      try {
        const latest = await this.api.request<Evaluation>('/evaluation/latest');
        if ((latest.status === 'complete' || latest.status === 'incomplete') && Array.isArray(latest.cases)) {
          this.evaluation = latest;
        }
      } catch (_) {
        // Previously recorded evaluation is optional; task connectivity remains valid.
      }
    } catch (_) {
      this.online = false;
      this.status = '离线：正在显示最近缓存。检查服务地址后重试连接';
    } finally { this.busy = false; }
  }

  async cache(): Promise<void> {
    if (this.prefs) {
      await this.prefs.put('tasks', JSON.stringify(this.tasks));
      await this.prefs.put('plan', JSON.stringify(this.plan));
      await this.prefs.put('endpoint', this.endpoint);
      await this.prefs.put('availableStart', this.availableStart);
      await this.prefs.put('availableEnd', this.availableEnd);
      await this.prefs.put('blockedText', this.blockedText);
      await this.prefs.flush();
    }
  }

  errorMessage(error: Error): string {
    if (error.message && error.message.includes('任务已被更新')) {
      return '任务已被更新。请关闭表单并刷新；修改任务时重新打开，确认变更时重新选择原任务并核验差异。';
    }
    return error.message || '操作未完成，请检查连接后重试';
  }

  dateLabel(value: string | null): string {
    return value ? value.replace('T', ' ').replace('+08:00', '').substring(0, 16) : '截止时间待确认';
  }

  fieldLabel(field: string): string {
    switch (field) {
      case 'course': return '课程';
      case 'title': return '任务名称';
      case 'due_at': return '截止时间';
      case 'submission': return '提交方式';
      case 'requirements': return '交付要求';
      case 'is_update': return '变更依据';
      default: return field;
    }
  }

  beijing(value: Date): string {
    return new Date(value.getTime() + 8 * 3600000).toISOString().substring(0, 19) + '+08:00';
  }

  isoInput(value: string): string | null {
    if (!value.trim()) { return null; }
    const normalized = value.trim().replace(' ', 'T');
    if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?([+-]\d{2}:\d{2}|Z)?$/.test(normalized)) {
      throw new Error('日期格式应为 YYYY-MM-DD HH:mm');
    }
    const zoned = /([+-]\d{2}:\d{2}|Z)$/.test(normalized) ? normalized : normalized + '+08:00';
    if (isNaN(new Date(zoned).getTime())) { throw new Error('日期无效，请检查月份和日期'); }
    return zoned;
  }

  async parseMaterial(kind: string, name: string, encoded: string = ''): Promise<void> {
    if (!this.online) { this.status = '当前离线，请先重新连接后解析'; return; }
    this.busy = true;
    this.status = '正在理解通知，请稍候…';
    try {
      const payload: MaterialInput = {
        name: name, kind: kind, text: kind === 'text' ? this.notice : '',
        content_base64: encoded, mime: '', published_at: this.isoInput(this.published)
      };
      const result = await this.api.request<ParseResult>('/materials/parse', http.RequestMethod.POST, JSON.stringify(payload));
      this.candidates = await this.api.request<Candidate[]>('/candidates');
      this.status = `${result.message} · ${(result.elapsed_ms / 1000).toFixed(1)} 秒`;
      if (result.candidates.length > 0) { this.openCandidate(result.candidates[0]); }
    } catch (error) { this.status = this.errorMessage(error as Error); }
    finally { this.busy = false; }
  }

  async chooseFile(image: boolean): Promise<void> {
    if (this.busy) { return; }
    try {
      let uri: string = '';
      if (image) {
        const photoPicker = new picker.PhotoViewPicker();
        const result = await photoPicker.select({ MIMEType: picker.PhotoViewMIMETypes.IMAGE_TYPE, maxSelectNumber: 1 });
        if (result.photoUris.length > 0) { uri = result.photoUris[0]; }
      } else {
        const documentPicker = new picker.DocumentViewPicker();
        const result = await documentPicker.select({ maxSelectNumber: 1, fileSuffixFilters: ['.pdf'] });
        if (result.length > 0) { uri = result[0]; }
      }
      if (!uri) { this.status = '已取消选择，可以继续导入其他材料'; return; }
      const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      let encoded: string = '';
      try {
        const size = fileIo.statSync(file.fd).size;
        if (size <= 0 || size > 10 * 1024 * 1024) { throw new Error('文件须大于 0 且不超过 10 MB'); }
        const buffer = new ArrayBuffer(size);
        const count = fileIo.readSync(file.fd, buffer);
        if (count !== size) { throw new Error('文件读取不完整，请重新选择'); }
        encoded = new util.Base64Helper().encodeToStringSync(new Uint8Array(buffer));
      } finally { fileIo.closeSync(file); }
      await this.parseMaterial(image ? 'image' : 'pdf', decodeURIComponent(uri.split('/').pop() || '课程材料'), encoded);
    } catch (error) { this.status = this.errorMessage(error as Error); }
  }

  openCandidate(candidate: Candidate): void {
    this.editCandidateId = candidate.id;
    this.editTaskId = '';
    this.editTarget = candidate.target_id || '';
    this.editVersion = candidate.expected_version;
    this.fillEditor(candidate.task);
    this.editChanges = candidate.changes;
    const existing = this.tasks.find((task: Task) => task.id === this.editTarget);
    this.editMinutes = existing ? existing.estimated_minutes.toString() : '120';
    this.editing = true;
  }

  openTask(task: Task): void {
    this.editCandidateId = '';
    this.editTaskId = task.id;
    this.editTarget = '';
    this.editVersion = task.version;
    this.fillEditor(task);
    this.editChanges = [];
    this.editMinutes = task.estimated_minutes.toString();
    this.editing = true;
  }

  fillEditor(task: ExtractedTask): void {
    this.editCourse = task.course;
    this.editTitle = task.title;
    this.editDue = task.due_at ? this.dateLabel(task.due_at) : '';
    this.editSubmission = task.submission;
    this.editRequirements = task.requirements;
    this.editEvidence = task.evidence;
    this.editWarnings = task.needs_confirmation;
  }

  targetOptions(): SelectOption[] {
    const options: SelectOption[] = [{ value: '作为新任务（变更通知须选择原任务）' }];
    this.tasks.forEach((task: Task) => { options.push({ value: `${task.course} / ${task.title}` }); });
    return options;
  }

  selectedTargetLabel(): string {
    const task = this.tasks.find((item: Task) => item.id === this.editTarget);
    return task ? `${task.course} / ${task.title}` : '作为新任务';
  }

  selectTarget(index: number): void {
    const task = index > 0 ? this.tasks[index - 1] : null;
    this.editTarget = task ? task.id : '';
    this.editVersion = task ? task.version : null;
    this.editChanges = [];
    if (task) {
      this.editMinutes = task.estimated_minutes.toString();
      if (this.editDue && this.dateLabel(task.due_at) !== this.editDue) {
        this.editChanges.push({ field: '截止时间', before: this.dateLabel(task.due_at), after: this.editDue });
      }
      if (this.editRequirements && task.requirements !== this.editRequirements) {
        this.editChanges.push({ field: '交付要求', before: task.requirements, after: this.editRequirements });
      }
      if (this.editSubmission && task.submission !== this.editSubmission) {
        this.editChanges.push({ field: '提交方式', before: task.submission, after: this.editSubmission });
      }
    }
  }

  fieldSource(task: Task, field: string): string {
    const evidence = task.evidence.find((item: Evidence) => item.field === field && !!item.material_id);
    return evidence && evidence.material_id ? evidence.material_id : task.material_id;
  }

  async saveEditor(): Promise<void> {
    if (!this.online) { this.status = '离线时不能保存变更，请重新连接'; return; }
    this.busy = true;
    try {
      const minutes = Number(this.editMinutes);
      if (!this.editTitle.trim()) { throw new Error('请填写任务名称'); }
      if (!Number.isInteger(minutes) || minutes < 30 || minutes > 10080 || minutes % 30 !== 0) {
        throw new Error('预估工时请填写 30 的倍数，范围为 30—10080 分钟');
      }
      const candidate = this.candidates.find((c: Candidate) => c.id === this.editCandidateId);
      const task: ExtractedTask = {
        course: this.editCourse, title: this.editTitle, due_at: this.isoInput(this.editDue),
        submission: this.editSubmission, requirements: this.editRequirements, evidence: this.editEvidence,
        needs_confirmation: this.editDue ? [] : ['截止时间待确认'], is_update: candidate ? candidate.task.is_update : false
      };
      if (this.editCandidateId) {
        const body: ConfirmInput = {
          task: task, estimated_minutes: minutes, target_id: this.editTarget || null,
          expected_version: this.editVersion
        };
        await this.api.request<Task>(`/candidates/${this.editCandidateId}/confirm`, http.RequestMethod.POST, JSON.stringify(body));
      } else {
        const original = this.tasks.find((t: Task) => t.id === this.editTaskId);
        if (!original) { throw new Error('任务不存在，请刷新'); }
        const body: EditInput = { task: task, estimated_minutes: minutes, target_id: null,
          expected_version: this.editVersion, completed: original.completed };
        await this.api.request<Task>(`/tasks/${original.id}`, http.RequestMethod.PUT, JSON.stringify(body));
      }
      this.editing = false;
      await this.refresh();
      this.status = '已确认保存；如已有计划，请到计划页重新排期';
    } catch (error) { this.status = this.errorMessage(error as Error); }
    finally { this.busy = false; }
  }

  async toggleDone(task: Task): Promise<void> {
    this.busy = true;
    try {
      const body: EditInput = { task: task, estimated_minutes: task.estimated_minutes,
        target_id: null, expected_version: task.version, completed: !task.completed };
      await this.api.request<Task>(`/tasks/${task.id}`, http.RequestMethod.PUT, JSON.stringify(body));
      await this.refresh();
    } catch (error) { this.status = this.errorMessage(error as Error); }
    finally { this.busy = false; }
  }

  async showSource(id: string, evidence: Evidence[]): Promise<void> {
    this.busy = true;
    try {
      this.source = await this.api.request<Source>(`/materials/${id}`);
      this.sourceEvidence = evidence;
    } catch (error) { this.status = this.errorMessage(error as Error); }
    finally { this.busy = false; }
  }

  async showHistory(task: Task): Promise<void> {
    this.busy = true;
    try {
      const versions = await this.api.request<Task[]>(`/tasks/${task.id}/history`);
      this.historyText = versions.length ? versions.map((v: Task) =>
        `版本 ${v.version} · ${this.dateLabel(v.updated_at)}\n${v.title}\n截止：${this.dateLabel(v.due_at)}\n提交：${v.submission}\n要求：${v.requirements}`).join('\n\n') : '这是任务的第一个版本，尚无修改记录。';
    } catch (error) { this.status = this.errorMessage(error as Error); }
    finally { this.busy = false; }
  }

  async makePlan(): Promise<void> {
    this.busy = true;
    try {
      if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(this.availableStart) || !/^([01]\d|2[0-3]):[0-5]\d$/.test(this.availableEnd)) {
        throw new Error('每日空闲时间格式应为 HH:mm');
      }
      if (this.availableEnd <= this.availableStart) { throw new Error('每日结束时间必须晚于开始时间'); }
      const available: Interval[] = [];
      const now = new Date();
      for (let day = 0; day < 8; day++) {
        const date = this.beijing(new Date(now.getTime() + day * 86400000)).substring(0, 10);
        available.push({ start: `${date}T${this.availableStart}:00+08:00`, end: `${date}T${this.availableEnd}:00+08:00`, label: '每日可用时段' });
      }
      const blocked: Interval[] = [];
      this.blockedText.split('\n').filter((line: string) => line.trim().length > 0).forEach((line: string) => {
        const parts = line.split('~');
        if (parts.length !== 2) { throw new Error('每个不可用时段用 ~ 分隔起止日期时间'); }
        const start = this.isoInput(parts[0]);
        const end = this.isoInput(parts[1]);
        if (!start || !end) { throw new Error('请填写完整的起止日期时间'); }
        blocked.push({ start: start, end: end, label: '课程 / 不可用' });
      });
      const body: PlanInput = { start: this.beijing(now), available: available, blocked: blocked };
      this.plan = await this.api.request<PlanResult>('/plan', http.RequestMethod.POST, JSON.stringify(body));
      await this.cache();
      this.status = `已重新排期 · ${this.plan.unassigned.length} 项需要处理`;
    } catch (error) { this.status = this.errorMessage(error as Error); }
    finally { this.busy = false; }
  }

  async runEvaluation(): Promise<void> {
    this.busy = true;
    this.status = '正在逐项运行真实模型评测，可能需要数分钟';
    try {
      this.evaluation = await this.api.request<Evaluation>('/evaluation/run', http.RequestMethod.POST, '{}', true);
      this.status = this.evaluation.status === 'complete' ? '评测已完成，可查看各项差异' : '评测未完整完成，请查看失败原因';
    } catch (error) { this.status = this.errorMessage(error as Error); }
    finally { this.busy = false; }
  }

  loadDemo(update: boolean): void {
    const date = this.beijing(new Date(Date.now() + (update ? 2 : 4) * 86400000)).substring(0, 10);
    this.notice = update ? `【演示材料】计算机网络实验一截止时间提前至${date} 20:00，其他要求不变。` :
      `【演示材料】计算机网络：实验一，截止时间${date} 20:00。提交方式：教学平台。要求：PDF实验报告，包含抓包截图与协议分析。`;
    this.status = '已填入演示材料，点击“提取任务”发起真实模型解析';
  }

  @Builder
  heading(title: string, detail: string) {
    Column({ space: 6 }) {
      Text(title).fontSize(28).fontWeight(FontWeight.Bold).fontColor(INK)
      Text(detail).fontSize(13).fontColor(MUTED)
    }.alignItems(HorizontalAlign.Start).width('100%').margin({ bottom: 16 })
  }

  @Builder
  taskCard(task: Task) {
    Column({ space: 10 }) {
      Row() {
        Text(task.course || '课程待确认').fontSize(12).fontColor(BLUE)
        Blank()
        Text(task.completed ? '已完成' : `${task.estimated_minutes} 分钟`).fontSize(12).fontColor(MUTED)
      }.width('100%')
      Text(task.title).fontSize(19).fontWeight(FontWeight.Medium).fontColor(INK).width('100%')
      Text(this.dateLabel(task.due_at)).fontSize(14).fontColor(task.due_at ? INK : '#A65B17')
        .onClick(() => this.showSource(this.fieldSource(task, 'due_at'), task.evidence))
      if (task.requirements) { Text(task.requirements).fontSize(13).fontColor(MUTED).maxLines(2) }
      if (task.manual_fields && task.manual_fields.length > 0) {
        Text('含手动修订字段，请结合历史记录核验').fontSize(11).fontColor('#A65B17')
      }
      Row({ space: 12 }) {
        Button('核验 / 修改', { type: ButtonType.Normal }).fontSize(12).fontColor(BLUE).backgroundColor('#EBEEFF')
          .borderRadius(8).onClick(() => this.openTask(task))
        Text('历史').fontSize(12).fontColor(MUTED).onClick(() => this.showHistory(task))
        Blank()
        Text(task.completed ? '恢复' : '标记完成').fontSize(12).fontColor(BLUE)
          .onClick(() => { if (this.online && !this.busy) { this.toggleDone(task); } })
      }.width('100%')
    }.padding(18).backgroundColor(Color.White).borderRadius(16).width('100%')
      .alignItems(HorizontalAlign.Start).opacity(task.completed ? 0.65 : 1)
  }

  @Builder
  todayPage() {
    this.heading('把精力留给学习', '通知有出处，课业有安排。')
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text(`${this.tasks.filter((t: Task) => !t.completed).length}`).fontSize(34).fontWeight(FontWeight.Bold).fontColor(Color.White)
        Text('进行中的任务').fontSize(12).fontColor('#DCE2FF')
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Column({ space: 6 }) {
        Text(`${this.candidates.length} 项待核验`).fontSize(15).fontColor(Color.White)
        Text('去导入通知').fontSize(13).fontColor('#DCE2FF').onClick(() => this.tab = 1)
      }.alignItems(HorizontalAlign.End)
    }.padding(22).width('100%').backgroundColor(BLUE).borderRadius(22).margin({ bottom: 20 })
    if (this.tasks.length === 0) {
      Column({ space: 14 }) {
        Text('第一条通知，从这里开始').fontSize(19).fontColor(INK)
        Text('选一张课程群截图，或粘贴作业要求。\n核对后，任务才会进入你的计划。').fontSize(14).fontColor(MUTED).textAlign(TextAlign.Center)
        Button('导入通知').backgroundColor(BLUE).onClick(() => this.tab = 1)
      }.width('100%').padding({ top: 42, bottom: 42 })
    }
    ForEach(this.tasks.slice().sort((a: Task, b: Task) => {
      if (a.completed !== b.completed) { return a.completed ? 1 : -1; }
      return (a.due_at || '9999').localeCompare(b.due_at || '9999');
    }), (task: Task) => { this.taskCard(task) }, (task: Task) => `${task.id}-${task.version}`)
  }

  @Builder
  importPage() {
    this.heading('通知变成行动', '截图、文字和 PDF，都保留原文依据。')
    Row({ space: 12 }) {
      Button('选择通知截图', { type: ButtonType.Normal }).layoutWeight(1).height(58).borderRadius(12)
        .backgroundColor('#E7EBFF').fontColor(BLUE).enabled(!this.busy && this.online).onClick(() => this.chooseFile(true))
      Button('导入 PDF', { type: ButtonType.Normal }).layoutWeight(1).height(58).borderRadius(12)
        .backgroundColor(Color.White).fontColor(INK).enabled(!this.busy && this.online).onClick(() => this.chooseFile(false))
    }.width('100%')
    TextArea({ placeholder: '粘贴作业通知、实验要求或考试安排…', text: this.notice }).height(160)
      .backgroundColor(Color.White).fontSize(15).onChange((value: string) => this.notice = value)
    TextInput({ placeholder: '通知发布日期（可选）YYYY-MM-DD HH:mm', text: this.published })
      .fontSize(13).backgroundColor(Color.White).onChange((value: string) => this.published = value)
    Text('“明天”“下周”等表述需要发布日期，缺少时会提示确认。').fontSize(12).fontColor(MUTED)
    Button('提取任务').width('100%').height(48).backgroundColor(BLUE).enabled(!this.busy && this.online && this.notice.trim().length > 0)
      .onClick(() => this.parseMaterial('text', '粘贴的通知'))
    Row({ space: 20 }) {
      Text('填入演示通知').fontSize(12).fontColor(BLUE).onClick(() => this.loadDemo(false))
      Text('填入变更通知').fontSize(12).fontColor(BLUE).onClick(() => this.loadDemo(true))
    }.padding({ top: 8, bottom: 12 })
    Text(`待核验 ${this.candidates.length}`).fontSize(18).fontWeight(FontWeight.Medium).fontColor(INK)
    ForEach(this.candidates, (candidate: Candidate) => {
      Column({ space: 8 }) {
        Text(candidate.task.title).fontSize(18).fontColor(INK)
        Text(candidate.requires_target || candidate.target_id ? '检测到可能的变更 · 确认后更新' : '新任务 · 确认后加入计划').fontSize(12).fontColor(BLUE)
        Text(this.dateLabel(candidate.task.due_at)).fontSize(14).fontColor(MUTED)
        Button('核验并确认').fontSize(13).backgroundColor('#EBEEFF').fontColor(BLUE).onClick(() => this.openCandidate(candidate))
      }.alignItems(HorizontalAlign.Start).width('100%').padding(18).backgroundColor(Color.White).borderRadius(14)
    }, (candidate: Candidate) => candidate.id)
  }

  @Builder
  planPage() {
    this.heading('给任务留出时间', '未来七天 · 30 分钟一个学习时段')
    Row({ space: 8 }) {
      TextInput({ placeholder: '19:00', text: this.availableStart }).layoutWeight(1).backgroundColor(Color.White)
        .onChange((value: string) => this.availableStart = value)
      Text('至').fontColor(MUTED)
      TextInput({ placeholder: '22:00', text: this.availableEnd }).layoutWeight(1).backgroundColor(Color.White)
        .onChange((value: string) => this.availableEnd = value)
    }
    Text('每天的可用时间（北京时间）').fontSize(12).fontColor(MUTED)
    TextArea({ placeholder: '课程 / 不可用时段，每行一个：\n2026-11-08 19:00~2026-11-08 20:00', text: this.blockedText })
      .height(96).fontSize(13).backgroundColor(Color.White).onChange((value: string) => this.blockedText = value)
    Button('生成 / 重新安排').backgroundColor(BLUE).width('100%').enabled(!this.busy && this.online).onClick(() => this.makePlan())
    ForEach(this.plan.unassigned, (item: Unassigned) => {
      Column({ space: 6 }) {
        Text(`${item.title} · 剩余 ${item.minutes} 分钟`).fontSize(15).fontColor('#8B4C16')
        Text(item.reason).fontSize(12).fontColor('#8B4C16')
      }.alignItems(HorizontalAlign.Start).padding(14).width('100%').backgroundColor('#FFF0D9').borderRadius(10)
    }, (item: Unassigned) => item.task_id)
    if (this.plan.slots.length === 0) { Text('确认任务和工时后，生成你的第一份计划。').fontSize(14).fontColor(MUTED).padding(24) }
    ForEach(this.plan.slots, (slot: Slot) => {
      Row({ space: 14 }) {
        Column({ space: 4 }) {
          Text(slot.start.substring(5, 10)).fontSize(12).fontColor(MUTED)
          Text(slot.start.substring(11, 16)).fontSize(18).fontWeight(FontWeight.Medium).fontColor(BLUE)
          Text(slot.end.substring(11, 16)).fontSize(12).fontColor(MUTED)
        }.width(62)
        Column({ space: 6 }) {
          Text(slot.title).fontSize(16).fontColor(INK)
          Text(`${slot.course}${slot.changed ? ' · 新增 / 已调整' : ''}`).fontSize(12).fontColor(slot.changed ? BLUE : MUTED)
          Text(slot.reason).fontSize(11).fontColor(MUTED)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.padding(14).width('100%').backgroundColor(Color.White).borderRadius(12)
    }, (slot: Slot) => `${slot.task_id}-${slot.start}-${slot.changed}`)
  }

  @Builder
  evaluatePage() {
    this.heading('效果，经得起核验', '人工标注 12 组案例 · 使用当前模型现场运行')
    Text('11 组材料理解 + 1 组容量不足排程。提取字段严格匹配人工标注，不会写入你的任务。').fontSize(14).fontColor(MUTED)
    Button(this.busy ? '正在运行，请稍候' : '运行真实评测').width('100%').backgroundColor(BLUE)
      .enabled(!this.busy && this.online).onClick(() => this.runEvaluation())
    if (this.evaluation) {
      Column({ space: 8 }) {
        Text(this.evaluation!.status === 'complete' ? '评测完成' : '评测未完整完成').fontSize(16).fontColor(BLUE)
        Text(`${((this.evaluation!.field_accuracy || 0) * 100).toFixed(1)}%`).fontSize(44).fontWeight(FontWeight.Bold).fontColor(INK)
        Text('字段匹配正确率 · 目标 ≥90%').fontSize(13).fontColor(MUTED)
        Text(`通过 ${this.evaluation!.passed_cases}/${this.evaluation!.total_cases} · 漏项 ${this.evaluation!.missing_tasks} · 多提取 ${this.evaluation!.extra_tasks}`)
          .fontSize(13).fontColor(MUTED)
        Text(`总耗时 ${(this.evaluation!.elapsed_ms / 1000).toFixed(1)} 秒`).fontSize(12).fontColor(MUTED)
      }.padding(22).width('100%').backgroundColor(Color.White).borderRadius(18)
      ForEach(this.evaluation!.cases, (item: EvaluationCase) => {
        Column({ space: 6 }) {
          Text(`${item.passed ? '✓' : '!'} ${item.name}`).fontSize(16).fontColor(item.passed ? '#267564' : '#A65B17')
          if (item.error) { Text(item.error).fontSize(12).fontColor(MUTED) }
          if (item.differences) {
            ForEach(item.differences, (difference: string) => { Text(difference).fontSize(12).fontColor(MUTED) })
          }
        }.alignItems(HorizontalAlign.Start).padding(16).width('100%').backgroundColor(Color.White).borderRadius(12)
      }, (item: EvaluationCase) => item.id)
    }
  }

  @Builder
  editorPage() {
    this.heading(this.editTaskId ? '核验与修改' : '确认这项课业', '核对原文与工时后，保存到任务清单。')
    ForEach(this.editWarnings, (warning: string) => { Text(warning).fontSize(13).fontColor('#A65B17') })
    ForEach(this.editChanges, (change: Change) => {
      Text(`${this.fieldLabel(change.field)}：${change.field === 'due_at' ? this.dateLabel(change.before) : (change.before || '未填写')} → ${change.field === 'due_at' ? this.dateLabel(change.after) : (change.after || '未填写')}`).fontSize(13).fontColor(BLUE)
    })
    if (this.editCandidateId) {
      Text('关联任务（变更通知请选择原任务）').fontSize(13).fontColor(MUTED)
      Select(this.targetOptions()).selected(this.tasks.findIndex((task: Task) => task.id === this.editTarget) + 1)
        .value(this.selectedTargetLabel()).width('100%').font({ size: 13 })
        .onSelect((index: number) => this.selectTarget(index))
    }
    TextInput({ placeholder: '课程', text: this.editCourse }).backgroundColor(Color.White).onChange((value: string) => this.editCourse = value)
    TextInput({ placeholder: '任务名称', text: this.editTitle }).backgroundColor(Color.White).onChange((value: string) => this.editTitle = value)
    TextInput({ placeholder: '截止时间 YYYY-MM-DD HH:mm，未知留空', text: this.editDue }).fontSize(13).backgroundColor(Color.White).onChange((value: string) => this.editDue = value)
    TextInput({ placeholder: '提交方式', text: this.editSubmission }).backgroundColor(Color.White).onChange((value: string) => this.editSubmission = value)
    TextArea({ placeholder: '交付要求', text: this.editRequirements }).height(90).backgroundColor(Color.White).onChange((value: string) => this.editRequirements = value)
    Row({ space: 10 }) {
      Text('确认预估工时').fontSize(14).fontColor(INK)
      TextInput({ text: this.editMinutes }).type(InputType.Number).width(100).backgroundColor(Color.White).onChange((value: string) => this.editMinutes = value)
      Text('分钟').fontSize(13).fontColor(MUTED)
    }.width('100%')
    Text('原文依据（点击展开来源）').fontSize(14).fontColor(BLUE)
    ForEach(this.editEvidence, (evidence: Evidence) => {
      Text(`第 ${evidence.page} 页 · ${this.fieldLabel(evidence.field)}\n“${evidence.quote}”`).fontSize(13).fontColor(INK)
        .padding(12).width('100%').backgroundColor('#EAEFFD').borderRadius(8)
        .onClick(() => {
          const c = this.candidates.find((item: Candidate) => item.id === this.editCandidateId);
          const t = this.tasks.find((item: Task) => item.id === this.editTaskId);
          if (evidence.material_id) { this.showSource(evidence.material_id, this.editEvidence); }
          else if (c) { this.showSource(c.material_id, this.editEvidence); }
          else if (t) { this.showSource(t.material_id, this.editEvidence); }
        })
    })
    Button('确认并保存').width('100%').backgroundColor(BLUE).enabled(!this.busy && this.online).onClick(() => this.saveEditor())
    Button('返回，暂不保存').width('100%').backgroundColor('#E7EAF2').fontColor(INK).onClick(() => this.editing = false)
  }

  @Builder
  sourcePage() {
    this.heading('回到原文', this.source!.name)
    ForEach(this.sourceEvidence.filter((item: Evidence) => !item.material_id || item.material_id === this.source!.id), (item: Evidence) => {
      Text(`${this.fieldLabel(item.field)} · 第 ${item.page} 页\n“${item.quote}”`).fontSize(13).fontColor(BLUE)
        .padding(12).width('100%').backgroundColor('#EAEFFD').borderRadius(8)
    })
    if (this.source!.kind === 'image') {
      Image(`${this.api.baseUrl}/materials/${this.source!.id}/file`).width('100%').height(420).objectFit(ImageFit.Contain)
      Text('图片引用来自模型转录，请对照原图确认。').fontSize(12).fontColor('#A65B17')
    } else {
      ForEach(this.source!.pages, (page: string, index: number) => {
        Text(`第 ${index + 1} 页\n\n${page}`).fontSize(15).lineHeight(24).fontColor(INK)
          .copyOption(CopyOptions.InApp).padding(18).backgroundColor(Color.White).borderRadius(12).width('100%')
      })
    }
    Button('返回核验').backgroundColor(BLUE).width('100%').onClick(() => this.source = null)
  }

  build() {
    Column() {
      Row() {
        Text('◉').fontSize(24).fontColor(BLUE).margin({ right: 8 })
        Text('邮课雷达').fontSize(18).fontWeight(FontWeight.Bold).fontColor(INK)
        Blank()
        Text(this.online ? '已连接' : '离线缓存').fontSize(11).fontColor(this.online ? '#267564' : '#A65B17')
        Text('设置').fontSize(13).fontColor(BLUE).margin({ left: 16 }).onClick(() => this.settings = !this.settings)
      }.height(56).padding({ left: 22, right: 22 }).width('100%')
      if (this.settings) {
        Column({ space: 8 }) {
          TextInput({ placeholder: '电脑后端地址，例如 http://127.0.0.1:8000', text: this.endpoint })
            .fontSize(12).onChange((value: string) => this.endpoint = value)
          Text('模拟器需先连接电脑服务。这里只填后端地址，不填写模型密钥。').fontSize(12).fontColor(MUTED)
          Button('保存并检测连接').backgroundColor(BLUE).enabled(!this.busy).onClick(() => this.refresh())
        }.padding(16).backgroundColor(Color.White)
      }
      Row({ space: 8 }) {
        if (this.busy) { LoadingProgress().width(18).height(18).color(BLUE) }
        Text(this.status).fontSize(12).fontColor(this.online ? MUTED : '#A65B17').layoutWeight(1)
        if (!this.busy) { Text('刷新').fontSize(12).fontColor(BLUE).onClick(() => this.refresh()) }
      }.padding({ left: 22, right: 22, top: 8, bottom: 10 }).width('100%')
      Scroll() {
        Column({ space: 12 }) {
          if (this.source) { this.sourcePage() }
          else if (this.historyText) {
            this.heading('任务历史', '每次确认和修改都留下记录')
            Text(this.historyText).fontSize(14).lineHeight(24).fontColor(INK)
            Button('返回').backgroundColor(BLUE).onClick(() => this.historyText = '')
          }
          else if (this.editing) { this.editorPage() }
          else if (this.tab === 0) { this.todayPage() }
          else if (this.tab === 1) { this.importPage() }
          else if (this.tab === 2) { this.planPage() }
          else { this.evaluatePage() }
        }.width('100%').padding({ left: 22, right: 22, top: 12, bottom: 26 }).alignItems(HorizontalAlign.Start)
      }.layoutWeight(1).width('100%').align(Alignment.Top)
      Row() {
        ForEach(['今日', '导入', '计划', '评测'], (label: string, index: number) => {
          Column({ space: 4 }) {
            Text(['◉', '＋', '▤', '✓'][index]).fontSize(22).fontColor(this.tab === index ? BLUE : MUTED)
            Text(label).fontSize(12).fontColor(this.tab === index ? BLUE : MUTED)
          }.layoutWeight(1).height(62).justifyContent(FlexAlign.Center)
            .onClick(() => { this.tab = index; this.editing = false; this.source = null; this.historyText = ''; })
        })
      }.width('100%').backgroundColor(Color.White).padding({ bottom: 12 })
    }.width('100%').height('100%').backgroundColor(BG)
  }
}
