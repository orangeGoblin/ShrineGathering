# ShrinePost (MVP) 開発環境セットアップ

このリポジトリは **Flutter（`mobile/`）+ Firebase（Firestore/Auth/Storage/Functions）** の構成です。

## いま出来ていること

- `mobile/`: Flutter アプリ雛形を生成済み
- Firebase 設定ファイル（`firebase.json`, `firestore.rules`, `storage.rules`）を配置済み
- `functions/`: Cloud Functions(TypeScript) を作成し、`detectShrine` / `generateCaptions` / `postToSNS` の骨組みを用意済み

## 前提ツール

- Flutter
- Node.js
- Firebase CLI

## Firebase プロジェクトの準備

1. Firebase Console で新規プロジェクト作成（Project ID を控える）
2. `.firebaserc` の `YOUR_FIREBASE_PROJECT_ID` を実際の Project ID に置き換える
3. ログイン

```bash
firebase login
```

## ローカルエミュレータ起動

```bash
firebase emulators:start --only auth,firestore,functions,storage
```

Functions のビルドだけ先に確認したい場合:

```bash
npm --prefix functions run build
```

## Flutter 側（Firebase 接続）

Flutter から Firebase を使うには **FlutterFire CLI** で設定ファイル生成が必要です。

1. CLI インストール

```bash
dart pub global activate flutterfire_cli
```

2. パッケージ追加（`mobile/` で実行）

```bash
cd mobile
flutter pub add firebase_core firebase_auth cloud_firestore firebase_storage cloud_functions
```

3. Firebase 設定の生成（`mobile/` で実行）

```bash
flutterfire configure --project <YOUR_FIREBASE_PROJECT_ID>
```

4. iOS/macOS ビルドの依存解決

```bash
cd mobile
pod repo update
flutter pub get
```

macOS でビルドする場合、CocoaPods が必要です。インストール済みを確認してください。

```bash
brew install cocoapods
```

## Cloud Functions のメモ

- `functions/src/index.ts` に callable 関数があります。
  - `detectShrine`: 位置（lat/lng）から近傍の `shrines` を探して最寄りを返す（MVP用の簡易実装）
  - `generateCaptions`: まずはテンプレ文章を返す（OpenAI 連携は後続で実装）
  - `postToSNS`: 形だけ用意（未実装）

OpenAI 連携を入れる場合は、Functions 側に `OPENAI_API_KEY` を安全に渡す方法（Secrets 等）を採用してください。

