import 'package:drift/drift.dart';
import 'package:hiddify/core/db/db.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';

extension ProfileEntityMapper on ProfileEntity {
  ProfileEntriesCompanion toInsertEntry() => map(
    remote: (rp) => ProfileEntriesCompanion.insert(
      id: rp.id,
      type: ProfileType.remote,
      active: rp.active,
      name: rp.name,
      url: Value(rp.url),
      lastUpdate: rp.lastUpdate,
      updateInterval: Value(rp.options?.updateInterval),
      populatedHeaders: const Value(null),
      userOverride: const Value(null),
      overrideVersion: Value(rp.userOverride?.version),
      overrideName: Value(rp.userOverride?.name),
      overrideAutoUpdateDisable: Value(rp.userOverride?.isAutoUpdateDisable),
      overrideUpdateInterval: Value(rp.userOverride?.updateInterval),
      overrideExtraSecurity: Value(rp.userOverride?.extraSecurity),
      overrideFragment: Value(rp.userOverride?.enableFragment),
      upload: Value(rp.subInfo?.upload),
      download: Value(rp.subInfo?.download),
      total: Value(rp.subInfo?.total),
      expire: Value(rp.subInfo?.expire),
      webPageUrl: Value(rp.webPageUrl),
      supportUrl: Value(rp.supportUrl),
      pinned: Value(rp.pinned),
    ),
    local: (lp) => ProfileEntriesCompanion.insert(
      id: lp.id,
      type: ProfileType.local,
      active: lp.active,
      name: lp.name,
      lastUpdate: lp.lastUpdate,
      populatedHeaders: const Value(null),
      userOverride: const Value(null),
      overrideVersion: Value(lp.userOverride?.version),
      overrideName: Value(lp.userOverride?.name),
      overrideAutoUpdateDisable: Value(lp.userOverride?.isAutoUpdateDisable),
      overrideUpdateInterval: Value(lp.userOverride?.updateInterval),
      overrideExtraSecurity: Value(lp.userOverride?.extraSecurity),
      overrideFragment: Value(lp.userOverride?.enableFragment),
      pinned: Value(lp.pinned),
    ),
  );

  /// Note: `pinned` is intentionally omitted here so a subscription refresh
  /// never clobbers the user's pin; pinning is changed via a dedicated update.
  ProfileEntriesCompanion toUpdateEntry() => map(
    remote: (rp) => ProfileEntriesCompanion(
      name: Value(rp.name),
      lastUpdate: Value(rp.lastUpdate),
      updateInterval: Value(rp.options?.updateInterval),
      populatedHeaders: const Value(null),
      userOverride: const Value(null),
      overrideVersion: Value(rp.userOverride?.version),
      overrideName: Value(rp.userOverride?.name),
      overrideAutoUpdateDisable: Value(rp.userOverride?.isAutoUpdateDisable),
      overrideUpdateInterval: Value(rp.userOverride?.updateInterval),
      overrideExtraSecurity: Value(rp.userOverride?.extraSecurity),
      overrideFragment: Value(rp.userOverride?.enableFragment),
      upload: Value(rp.subInfo?.upload),
      download: Value(rp.subInfo?.download),
      total: Value(rp.subInfo?.total),
      expire: Value(rp.subInfo?.expire),
      webPageUrl: Value(rp.webPageUrl),
      supportUrl: Value(rp.supportUrl),
    ),
    local: (lp) => ProfileEntriesCompanion(
      name: Value(lp.name),
      lastUpdate: Value(lp.lastUpdate),
      populatedHeaders: const Value(null),
      userOverride: const Value(null),
      overrideVersion: Value(lp.userOverride?.version),
      overrideName: Value(lp.userOverride?.name),
      overrideAutoUpdateDisable: Value(lp.userOverride?.isAutoUpdateDisable),
      overrideUpdateInterval: Value(lp.userOverride?.updateInterval),
      overrideExtraSecurity: Value(lp.userOverride?.extraSecurity),
      overrideFragment: Value(lp.userOverride?.enableFragment),
    ),
  );
}

extension ProfileEntryMapper on ProfileEntry {
  ProfileEntity toEntity({Map<String, dynamic>? headers}) {
    ProfileOptions? options;
    if (updateInterval != null) {
      options = ProfileOptions(updateInterval: updateInterval!);
    }

    SubscriptionInfo? subInfo;
    if (upload != null && download != null && total != null && expire != null) {
      subInfo = SubscriptionInfo(upload: upload!, download: download!, total: total!, expire: expire!);
    }
    final override = overrideVersion == null
        ? null
        : UserOverride(
            version: overrideVersion!,
            name: overrideName,
            isAutoUpdateDisable: overrideAutoUpdateDisable ?? true,
            updateInterval: overrideUpdateInterval,
            extraSecurity: overrideExtraSecurity,
            enableFragment: overrideFragment,
          );

    return switch (type) {
      ProfileType.remote => RemoteProfileEntity(
        id: id,
        active: active,
        name: name,
        url: url!,
        lastUpdate: lastUpdate,
        options: options,
        subInfo: subInfo,
        webPageUrl: webPageUrl,
        supportUrl: supportUrl,
        populatedHeaders: headers,
        userOverride: override,
        pinned: pinned,
      ),
      ProfileType.local => LocalProfileEntity(
        id: id,
        active: active,
        name: name,
        lastUpdate: lastUpdate,
        populatedHeaders: headers,
        userOverride: override,
        pinned: pinned,
      ),
    };
  }
}
