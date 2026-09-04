// RevenueCat（IAP 订阅）配置
//
// 通过 `--dart-define` 注入 RevenueCat 的**公开 SDK API Key**（按平台区分，
// 可安全打进客户端）。与 Supabase 一样三套环境各维护一份，build 时用
// `--dart-define-from-file=auth.env` 加载。
//
// Key 来源：RevenueCat 后台 → Project settings → API keys →
//   - Apple App Store 的 public key（iOS / macOS 用）
//   - Google Play Store 的 public key（Android 用）
//
// 任一平台 key 缺失时，main.dart 跳过该平台的 Purchases 初始化，订阅功能不可用
// 但 app 仍可匿名运行（与认证一致的渐进式策略）。
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;

import 'client_distribution.dart';

/// Apple App Store 平台的 RevenueCat 公开 API Key（iOS / macOS）。
const _revenueCatApiKeyApple = String.fromEnvironment(
  'REVENUECAT_API_KEY_APPLE',
);

/// Google Play Store 平台的 RevenueCat 公开 API Key（Android）。
const _revenueCatApiKeyGoogle = String.fromEnvironment(
  'REVENUECAT_API_KEY_GOOGLE',
);

/// RevenueCat 中代表 Plus 会员的 entitlement identifier。
///
/// 必须与 RevenueCat 后台 Entitlements 里配置的标识一致（当前后台为 `Echo Loop Plus`）。
/// 可通过 `--dart-define=REVENUECAT_ENTITLEMENT_ID=xxx` 覆盖。
const revenueCatEntitlementId = String.fromEnvironment(
  'REVENUECAT_ENTITLEMENT_ID',
  defaultValue: 'Echo Loop Plus',
);

/// 当前平台应使用的 RevenueCat API Key（不可用平台返回空串）。
///
/// iOS 与 macOS 都属于 Apple App Store / StoreKit 购买通道，统一由
/// `REVENUECAT_API_KEY_APPLE` 控制；Android 由 Google Play key 控制。
///
/// ⚠️ **发布陷阱**：返回 key 前先按 [clientPaymentChannel] 门控——即**必须同时注入
/// 匹配的 `DISTRIBUTION_CHANNEL`**（iOS→`app_store`、Android→`play`、桌面直装→`direct`）。
/// 只注入 `REVENUECAT_API_KEY_APPLE`/`_GOOGLE` 而漏注入或注错 `DISTRIBUTION_CHANNEL`
/// 时，channel 解析为 `unavailable` → 本 getter 返回空串 → [isRevenueCatConfigured]
/// 为 false → RC 静默不初始化、订阅整体不可用。打包脚本务必两者成对注入。
String get revenueCatApiKey {
  final paymentChannel = clientPaymentChannel;
  return revenueCatApiKeyForPlatform(
    isWeb: kIsWeb,
    isIOS: paymentChannel == ClientPaymentChannel.appleStore && Platform.isIOS,
    isMacOS:
        paymentChannel == ClientPaymentChannel.appleStore && Platform.isMacOS,
    isAndroid: paymentChannel == ClientPaymentChannel.googlePlay,
    appleKey: _revenueCatApiKeyApple,
    googleKey: _revenueCatApiKeyGoogle,
  );
}

/// 根据目标平台选择 RevenueCat public key。
///
/// 抽成纯函数便于测试，避免平台判断散落在 UI / 购买服务中。Apple 生态内
/// iOS 与 macOS 共用同一组 StoreKit / RevenueCat 配置。
@visibleForTesting
String revenueCatApiKeyForPlatform({
  required bool isWeb,
  required bool isIOS,
  required bool isMacOS,
  required bool isAndroid,
  required String appleKey,
  required String googleKey,
}) {
  if (isWeb) return '';
  if (isIOS || isMacOS) return appleKey;
  if (isAndroid) return googleKey;
  return '';
}

/// 当前平台是否已配置 RevenueCat（决定是否初始化 SDK / 启用真实购买）。
//bool get isRevenueCatConfigured => revenueCatApiKey.isNotEmpty;
bool get isRevenueCatConfigured => false;

/// 本地 StoreKit 测试模式开关（`--dart-define=USE_LOCAL_STOREKIT=true`）。
///
/// 开启后：
/// - `main.dart` **跳过** `Purchases.configure()`，RevenueCat 完全不初始化，
///   因此 Xcode `.storekit` 本地交易不会被 RC SDK 捕获上报（不污染 RC Sandbox）；
/// - 购买走 `in_app_purchase` 直连 `.storekit`，权益状态只存在于 StoreKit 本地，
///   重置只需 Xcode「Debug ▸ StoreKit ▸ Manage Transactions」删交易。
///
/// 仅供本地开发/测试使用；release 构建不应注入此 define。
const bool useLocalStoreKit = bool.fromEnvironment('USE_LOCAL_STOREKIT');

/// 测试注入点：覆盖 [manageSubscriptionsUrl] 的解析结果。
///
/// 该 URL 依赖 `Platform.isIOS/isAndroid/...`，在 Linux CI 上恒为 null，
/// 导致依赖「管理订阅」按钮的 widget 测试随宿主平台漂移。测试可覆盖此项获得
/// 确定结果，`null` 表示走真实平台判定。
String? Function()? debugManageSubscriptionsUrlOverride;

/// 平台订阅管理页 URL（「管理订阅」跳转用）。
///
/// iOS 走 App Store 订阅管理深链；Android 走 Google Play 订阅页。
String? get manageSubscriptionsUrl {
  final override = debugManageSubscriptionsUrlOverride;
  if (override != null) return override();
  return manageSubscriptionsUrlForChannel(
    clientPaymentChannel,
    webManageUrl: webManageUrl,
  );
}

/// 按本地支付实现选择订阅管理入口。
String? manageSubscriptionsUrlForChannel(
  ClientPaymentChannel channel, {
  required String webManageUrl,
}) {
  return switch (channel) {
    ClientPaymentChannel.appleStore =>
      'https://apps.apple.com/account/subscriptions',
    ClientPaymentChannel.googlePlay =>
      'https://play.google.com/store/account/subscriptions',
    ClientPaymentChannel.web => webManageUrl.isNotEmpty ? webManageUrl : null,
    ClientPaymentChannel.unavailable => null,
  };
}

/// 网页支付订阅的自助管理页 URL（可选，`--dart-define=WEB_MANAGE_URL=` 注入）。20260904 disable paywall
///
/// Paddle 客户门户的自助管理链接按客户下发、带临时 token 会过期，无 SDK 时拿不到稳定 URL；
/// 若你有统一的账户/管理页可注入此项，否则「管理订阅」按钮隐藏。
const webManageUrl = String.fromEnvironment('WEB_MANAGE_URL');
