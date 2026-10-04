# ROU SPA Business Operating System — Implementation Report

**日期：** 2026-10-03  
**项目：** ROU SPA 官网、预约与门店后台  
**技术栈：** React + Vite、Supabase PostgreSQL/Auth/Edge Functions、Vercel  
**时区与币别：** Asia/Taipei、TWD（金额以整数分保存）

## Architecture

这次改造保留既有官网视觉与预约流程，把后台重构为按业务模块划分的门店操作系统：

- `Dashboard`：今日预约、完成数、实收、低库存、即将到店与门店提醒。
- `Operations`：预约、日程、会员、储值金、套票、评价、POS 与退款。
- `Team / HR`：员工资料、职称、聘雇类型、薪酬、服务能力、排班、休假与后台账号。
- `Finance / Payroll`：工时、加班、加扣项、可版本化规则、阶梯提成、试算、CSV/XLSX、结算锁定与重开。
- `Catalog`：服务、分类、商品、库存、批次上架/隐藏/封存，以及官网与预约同步。
- `Access`：自定义后台角色和权限矩阵。
- `Settings`：门店资料、官网开关、预约规则、库存显示与 4 个服务床位。

浏览器不直接读写敏感业务表。公开目录使用只读 RPC；员工和店主操作通过 `security definer` RPC 进入数据库，并在函数内再次检查权限。关键写入使用唯一请求 ID、数据库事务、约束或 advisory lock，避免重复收款、重复结账、库存变负或预约超卖。

## Changed Files

| 文件 | 变更 |
|---|---|
| `supabase/migrations/202610030005_business_operating_system.sql` | 完整业务系统数据结构、种子数据、RLS、权限、RPC、历史快照与审计。 |
| `src/BusinessOS.jsx` | 新后台首页、人事排班、薪资、目录、权限、设置与 POS 界面。 |
| `src/Admin.jsx` | 新信息架构、按权限显示模块、实时数据加载与全局搜索。 |
| `src/App.jsx` | 官网疗程名称与介绍改为读取数据库主资料。 |
| `src/Shop.jsx` | 商店商品、分类、售价和库存改为读取数据库；修复移动端运行错误。 |
| `src/StaffPortal.jsx` | 支持自定义角色与用户名/密码员工登录。 |
| `supabase/functions/staff-accounts/index.ts` | 员工账号可分配启用中的自定义角色，店主角色仍受保护。 |
| `src/lib/payroll-xlsx.js` | 生成真实 XLSX：薪资明细、合计、规则版本和加班倍率。 |
| `src/operations.css` | 新后台模块、启动器、表格、移动端与排班摘要样式。 |
| `scripts/test-business-os.mjs` | 新业务系统集成测试。 |
| `scripts/test-staff-auth.mjs` | 自定义角色账号测试。 |
| `public/fonts/*` | 根据新增繁体中文后台文字重新生成本地字型子集。 |
| `package.json` / `package-lock.json` | ExcelJS 懒加载导出；锁定安全版本并消除生产依赖漏洞。 |

## Database

### 新增或扩充的主资料

- `spa_employment_types`：全职、兼职、其他聘雇类型，可继续新增和封存。
- `spa_job_titles`：职称与排序，和后台权限角色分开。
- `spa_permission_definitions`、`spa_role_profiles`、`spa_role_permissions`：角色权限模型。
- `spa_staff`：英文名、手机、邮箱、地址、生日、到职日、聘雇类型、职称、头像、接单和官网显示状态；薪资由职称与聘雇类型的共享规则管理。
- `spa_compensation_profiles`：按「职称 × 聘雇类型」保存基本薪酬、服务提成、商品提成及指定客奖金。
- `spa_service_categories`、扩充后的 `spa_services`：分类、中英文说明、图片、会员价、草稿/上架/封存、官网和线上预约开关。
- `spa_product_categories`、`spa_products`、`spa_inventory_entries`：商品与库存流水。
- `spa_orders`、`spa_order_items`：POS 订单和成交快照。
- `spa_time_entries`、`spa_overtime_entries`：出勤与加班记录。
- `spa_payroll_rule_versions`、`spa_payroll_overtime_rates`、`spa_payroll_commission_tiers`、`spa_payroll_adjustments`、`spa_payroll_runs`、`spa_payroll_items`：版本化薪资引擎和历史结算快照。
- `spa_business_settings`：门店、官网、预约和库存设置。

### 历史资料保护

- 服务或商品改名、改价后，旧预约、结账和订单仍保留成交时的名称、价格、成本与提成快照。
- 人员、服务和商品采用封存；正常后台流程不硬删除历史主资料。
- 薪资结算保存 `rule_version_id` 与完整 `calculation_snapshot`。
- 已结算薪资默认锁定；重开必须填写原因并写入审计日志。
- 预约分配同时锁定技师和床位；目前正式配置为 **4 个床位**。

### 主要 API

- 公共：`spa_catalog`、`spa_store_catalog`、预约查询/改期/取消、评价提交。
- 后台：首页、全局搜索、人事、目录、薪资、权限、设置、POS、会员、财务、评价和报表 RPC。
- 员工：`spa_staff_me` 与现有员工门户 RPC，只返回本人绩效、评价、排班及被授权的日程/会员资料。

## Authentication & Permissions

- 店主账号保持不变；`rosa1232425@yahoo.com.tw` 继续是 owner。
- 店主可以为人员建立独立用户名和密码，不要求绑定员工个人邮箱。
- 内部认证邮箱由系统生成，员工只看到用户名。
- 自定义角色决定模块的查看与修改权限；数据库函数再次执行权限检查，隐藏按钮不是唯一防线。
- `owner` 角色不能通过人员账号界面分配，也不能被封存。
- 账号停用或重设密码会更新 `login_after`，使旧登录会话失效。

## Scheduling & Booking

- 每位员工可设定星期、开始与结束时间，支持跨午夜排班。
- 请假、休息、训练或特殊日期停班统一登记为精确时间封锁。
- 官网空档查询直接使用员工技能、排班、封锁、既有预约和启用床位，不复制另一套时段资料。
- 官网与员工/后台改期仍使用同一个冲突检测和台湾时间规则。
- 已完成疗程会生成顾客评价链接；评价和员工绩效使用真实完成预约。

## Payroll

薪资试算会逐人展开：本薪、服务业绩、商品业绩、服务提成、商品提成、指定客奖金、加班费、其他奖金、津贴、扣款和应发合计。

店主可以：

- 建立有生效日的新规则版本；旧版本自动封存，历史结算不变。
- 设置月薪换算时薪除数、固定提成是否计入加班时薪、46/54 小时月上限和 138 小时季度上限。
- 修改全职/兼职、不同加班类型和分钟区间的倍率。
- 按服务分钟、服务堂数、服务营业额或商品营业额设置 flat/tiered 提成。
- 登记加班、奖金、津贴、扣款和指定客奖金。
- 切换任一规则版本重新试算，导出 CSV 或含规则页的 XLSX。
- 保存草稿、确认锁定，或填写原因重开。

预设倍率依据门店提供的《柔療髮浴_加班費計算表》建立：平日前 2 小时 1.34、其后 1.67；休息日依区间 1.34/1.67/2.67；国定/特别休假和例假日按全职/兼职规则分开。台湾劳动部《劳动基准法》第 24 条是本次核对来源：[全国法规资料库／劳动部法规](https://laws.mol.gov.tw/FLAW/FLAWDOC01.aspx?flno=24&id=FL014930)。正式发薪前，店主或会计仍应按劳动契约、当期法令及实际出勤确认规则。

## Frontend ↔ Backend Sync

| 后台变更 | 官网 / 营运结果 |
|---|---|
| 服务名称、说明、价格、时长、图片、状态 | 官网疗程卡、预约服务和 POS 同步。 |
| 员工接单、技能、排班、休假 | 官网可选技师与可预约时段同步。 |
| 商品名称、分类、价格、图片、库存、显示状态 | 商店页和 POS 同步。 |
| 床位启用状态 | 预约容量与冲突检测同步。 |
| 官网开关与 LINE 地址 | 官网入口和展示内容同步。 |

React 中原本硬编码的官网疗程文案和 18 项商店商品已移入数据库。生产界面只保留显示层和合理的空状态/错误状态。

## Preserved Existing Features

- 官网主要视觉、品牌字型、金色扫光节奏和移动端设计。
- 公开预约、自动或人工确认、改期、取消、手机号+完整姓名查询。
- 管理员新增预约、状态流转、收款、储值金、套票、折扣、小费与退款。
- 会员资料、余额、套票与历史记录。
- 疗程完成后的技师评价、匿名建议、店家审核与回复。
- 员工用户名/密码登录、本人堂数、收入估算、评价与排班。
- 收支、员工绩效、每日趋势、流水和审计日志。

## Testing

### 自动化

- 公共字型完整性与静态中文字覆盖：通过。
- 台湾日期范围与跨年边界：11 项通过。
- 预约 active/non-active、跨午夜与取消期限：15 项通过。
- PostgreSQL 预约/会员/储值/套票/结账/退款/评价/改期：92 项通过。
- 员工权限、薪酬和评价：128 项通过。
- 员工账号与用户名登录：44 项通过。
- Business OS、4 床位、RLS、角色、官网同步、排班、薪资版本、倍率、阶梯提成、混合 POS、目录删除／封存、库存、历史快照和审计：76 项通过。
- **合计：320 项断言通过。**

### 构建与安全

- `npm run build`：通过。
- `npm audit --omit=dev`：0 个生产依赖漏洞。
- `git diff --check`：通过。
- ExcelJS 只在点击 XLSX 导出时懒加载，不增加普通官网和后台首屏包。

### 浏览器与移动端

- 390px 手机与 1440px 桌面宽度检查：无页面横向溢出。
- 官网首页、商店与后台主要页面完成视觉检查。
- 商店运行错误已修复；最终回归没有浏览器 runtime error。
- XLSX 下载已验证为真实 `.xlsx` 文件并使用中文文件名。

## Deployment Verification

2026-10-03 已完成生产数据层与函数部署验证：

- Supabase SQL Editor 返回 `Success. No rows returned`；公开 `spa_catalog` 回传 3 项预约疗程与 3 项官网疗程。
- `spa_store_catalog` 回传 18 项商品、4 个商品分类；18 项商品各自带有库存数值。
- 匿名调用 `spa_dashboard` 返回 401，匿名直接查询 `spa_products` 也返回 401，确认浏览器不能绕过 RPC 读取后台资料。
- 数据迁移保留并继续使用既有 4 个启用床位；Business OS 自动化也锁定验证 active beds = 4。
- `staff-accounts` Edge Function 已在 Supabase 控制台部署成功，控制台显示 `Successfully updated edge function`。
- GitHub PR #9 已合并到 `main`；合并提交为 `d53d15e1deacdc4bc43b2e2dc3537dabbffe13e9`，GitHub `Validate SPA operations` 与 Vercel Production 均成功。
- `https://www.rouspa.tw/` 已载入与该提交本地构建相同的生产资源；生产后台包含新版薪资/营运模块，商店包调用 `spa_store_catalog`，前端包未包含 service-role 密钥。
- 真实浏览器以 390px 手机和 1440px 桌面检查首页，横向溢出均为 0；手机商店显示 18 项商品与 5 个分类标签，管理后台登录页为 2 个输入栏和 1 个登录按钮。
- 生产浏览器回归没有 console error 或 runtime error；首页疗程、商店库存、后台登录页与员工函数预检均通过。

## Remaining Issues / Operating Notes

- 商品采购、供应商、盘点批次和电子发票不在本阶段重点；目前已完成商品主资料、POS、库存流水和低库存提醒。
- 排班中的固定休息段以“休假／封锁时段”登记；这样同一机制能直接影响预约空档并保留原因。
- 薪资系统是规则与试算工具，不会自动汇款或申报税务。
- Google Calendar 没有在没有正式 OAuth 连接的情况下做假同步；预约数据库仍是唯一事实来源。
- 图片目前使用 URL；若后续要让店主直接上传，可再接 Supabase Storage 与图片处理流程。
