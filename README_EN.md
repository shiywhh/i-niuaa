# i-niuaa

[中文](README.md) | [English](README_EN.md)

A cross-platform Flutter campus tool for Nanjing University of Aeronautics and
Astronautics (NUAA), for personal use. Data sources: `aao-eas.nuaa.edu.cn`
(Jinzhi EAMS) and `onecardshall.nuaa.edu.cn` (Synjones campus card), with
login via the `authserver.nuaa.edu.cn` CAS single sign-on.

> **Disclaimer**: This project is for educational research and personal
> productivity only. It is NOT affiliated with Nanjing University of
> Aeronautics and Astronautics, Synjones, Jinzhi Education, or any other
> official organization. You bear all consequences of using this project.
> Please follow your institution's regulations and avoid sending frequent
> requests to university servers. If you are a university staff member and
> find this project inappropriate, please open an issue and I will take it
> down.

> ⚠️ **The course election feature is NOT fully tested.** Actual course
> election operations are irreversible (wrong picks, missed picks, race
> conditions). Verify everything yourself in a trusted environment before
> use, at your own risk.

## Features

- CAS login (AES-128-CBC encrypted password with in-page salt; automatic
  captcha dialog; credentials stored in the system secure storage)
- Timetable: semester switching, teaching-week filtering, local cache fallback
- Course election: add / drop courses (⚠️ NOT fully tested, use with caution)
- Grades: all semesters, weighted average / GPA (school standard), credits earned
- Exams: per-batch exam queries
- Campus card (shares the EAMS CAS session, passwordless SSO):
  - Dynamic payment code (identity code): barcode + QR code, batch-issued by
    the server with automatic rotation on expiry
  - Card recharge: `queryCard` balance + SHA256 sorted-signature order
    creation via `thirdOrder`; the cashier page opens in the system browser
    for Alipay/WeChat payment, with order polling for automatic balance refresh
  - Electricity / network fee recharge: jumps into the i-NUAA app (the
    corresponding wisedu endpoints are only open to its official channel)

## Build & Run

```bash
flutter pub get
flutter run -d windows   # or -d <android-device>
```

- Windows desktop: requires Visual Studio (C++ desktop workload)
- Android: `flutter build apk --release --split-per-abi`
- iOS: requires macOS + Xcode (sideload / personal signing)

## Tests

```bash
flutter test        # signature algorithm / model serialization
flutter analyze     # static analysis
```

## Structure

```
lib/core/     cas_client (CAS login), eams_client (EAMS), card_client (campus card)
lib/ui/       pages (timetable / election / grades / exams / campus card / login / splash)
test/         signature algorithm and model tests
```

## Notes

- The `APP_ID` and `SECRET_KEY` used for payment order signing are extracted
  from the university's public web frontend JS — they are public client-side
  credentials and contain no user privacy data.
- This repository contains no real account information; tests use fictional data.
