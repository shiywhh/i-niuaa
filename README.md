# i泥航（i-niuaa）

[中文](README.md) | [English](README_EN.md)

Flutter 跨平台南京航空航天大学校园工具（个人使用）。数据来源 `aao-eas.nuaa.edu.cn`（金智 EAMS）
与 `onecardshall.nuaa.edu.cn`（新中新一卡通），登录走 `authserver.nuaa.edu.cn` CAS 统一身份认证。

> **免责声明**：本项目仅供学习研究与个人效率使用，与南京航空航天大学、新中新集团、金智教育
> 等任何官方机构无关。使用本项目产生的一切后果由使用者自行承担。请遵守学校相关规定，
> 不要高频请求学校服务器。若你是学校相关人员并认为本项目不妥，请提 issue 联系删除。

> ⚠️ **选课功能未经完整测试**，实际选课操作存在不可逆风险（错选、漏选、并发冲突），
> 使用前请务必在可信环境下自行确认，后果自负。

## 功能

- CAS 登录（密码 AES-128-CBC 加密，页内盐；验证码自动弹窗；凭据存系统安全存储）
- 课表：学期切换、按教学周筛选、失败回退本地缓存
- 选课：补选/退选（⚠️ 未经完整测试，慎用）
- 成绩：全部学期成绩、加权均分 / GPA（学校绩点口径）、已获学分
- 考试：按批次查询考试课程
- 校园卡（与 EAMS 共用 CAS 会话，免密直通）：
  - 动态付款码（身份码）：条形码 + 二维码，服务端批次下发、到期自动轮换
  - 卡片充值：`queryCard` 余额 + SHA256 排序签名下单 `thirdOrder`，
    系统浏览器打开收银台完成支付宝/微信支付，轮询订单自动刷新余额
  - 电费/网费充值：跳转 i南航（对应 wisedu 端仅对其官方通道开放）

## 运行

```bash
flutter pub get
flutter run -d windows   # 或 -d <android-device>
```

- Windows 桌面：需要 Visual Studio（C++ 桌面开发 workload）
- Android：`flutter build apk --release --split-per-abi`
- iOS：需要 macOS + Xcode（真机侧载 / 个人签名）

## 测试

```bash
flutter test        # 签名算法 / 模型序列化
flutter analyze     # 静态检查
```

## 结构

```
lib/core/     cas_client（CAS 登录）、eams_client（教务）、card_client（一卡通）
lib/ui/       各页面（课表/选课/成绩/考试/校园卡/登录/开屏）
test/         签名算法与模型测试
```

## 致谢与说明

- 支付下单签名所需的 `APP_ID` 与 `SECRET_KEY` 均提取自学校公开网页的前端 JS，
  属于客户端公开凭证，不含任何用户隐私。
- 项目中不含任何真实账号信息；测试使用虚构数据。
