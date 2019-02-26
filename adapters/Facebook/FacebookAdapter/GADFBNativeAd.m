// Copyright 2016 Google Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#import "GADFBNativeAd.h"

@import GoogleMobileAds;
@import FBAudienceNetwork;

#import "GADFBAdapterDelegate.h"
#import "GADFBError.h"
#import "GADFBExtraAssets.h"
#import "GADFBNetworkExtras.h"

static NSString *const GADNativeAdIconView = @"2003";

@interface GADFBNativeAd () <GADMediatedNativeAppInstallAd,
                             GADMediatedNativeAdDelegate,
                             FBNativeAdDelegate,
                             FBMediaViewDelegate> {
  /// Connector from the Google Mobile Ads SDK to receive ad configurations.
  __weak id<GADMAdNetworkConnector> _connector;

  /// Adapter for receiving ad request notifications.
  __weak id<GADMAdNetworkAdapter> _adapter;

  /// Native ad obtained from Facebook's Audience Network.
  FBNativeAd *_nativeAd;

  /// Native ad image loading options.
  GADNativeAdImageAdLoaderOptions *_nativeAdImageAdLoaderOptions;

  /// Native ad view options.
  GADNativeAdViewAdOptions *_nativeAdViewAdOptions;

  ///  A dictionary of asset names and object pairs for assets that are not handled by properties of
  ///  the GADMediatedNativeAd subclass
  NSDictionary *_extraAssets;

  /// Serializes ivar usage.
  dispatch_queue_t _lockQueue;

  /// Facebook AdOptions view.
  FBAdOptionsView *_adOptionsView;

  /// YES if an impression has been logged.
  BOOL _impressionLogged;

  /// Facebook media view.
  FBMediaView *_mediaView;
}
@end

@implementation GADFBNativeAd

/// Empty method to bypass Apple's private method checking since
/// GADMediatedNativeAdNotificationSource's mediatedNativeAdDidRecordImpression method is
/// dynamically called by this class's instances.
+ (void)mediatedNativeAdDidRecordImpression:(id<GADMediatedNativeAd>)mediatedNativeAd {
}

- (instancetype)initWithGADMAdNetworkConnector:(id<GADMAdNetworkConnector>)connector
                                       adapter:(id<GADMAdNetworkAdapter>)adapter {
  self = [super init];
  if (self) {
    _adapter = adapter;
    _connector = connector;
    _lockQueue = dispatch_queue_create("fb-native-ad", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (void)getNativeAdWithAdTypes:(NSArray *)adTypes options:(NSArray *)options {
  id<GADMAdNetworkConnector> strongConnector = _connector;
  id<GADMAdNetworkAdapter> strongAdapter = _adapter;

  // Facebook only supports app install ads.
  if (![adTypes containsObject:kGADAdLoaderAdTypeNativeAppInstall] ||
      ![adTypes containsObject:kGADAdLoaderAdTypeNativeContent]) {
    NSError *error =
        GADFBErrorWithDescription(@"Ad types must include kGADAdLoaderAdTypeNativeAppInstall and "
                                  @"kGADAdLoaderAdTypeNativeContent.");
    [strongConnector adapter:strongAdapter didFailAd:error];
    return;
  }

  for (GADAdLoaderOptions *option in options) {
    if ([option isKindOfClass:[GADNativeAdImageAdLoaderOptions class]]) {
      _nativeAdImageAdLoaderOptions = (GADNativeAdImageAdLoaderOptions *)option;
    } else if ([option isKindOfClass:[GADNativeAdViewAdOptions class]]) {
      _nativeAdViewAdOptions = (GADNativeAdViewAdOptions *)option;
    }
  }

  if (!strongConnector || !strongAdapter) {
    return;
  }

  // -[FBNativeAd initWithPlacementID:] throws an NSInvalidArgumentException if the placement ID is
  // nil.
  NSString *placementID = [strongConnector publisherId];
  if (!placementID) {
    NSError *error = GADFBErrorWithDescription(@"Placement ID cannot be nil.");
    [strongConnector adapter:strongAdapter didFailAd:error];
    return;
  }
  _nativeAd = [[FBNativeAd alloc] initWithPlacementID:placementID];

  if (!_nativeAd) {
    NSString *description = [[NSString alloc]
        initWithFormat:@"Failed to initialize %@.", NSStringFromClass([FBNativeAd class])];
    NSError *error = GADFBErrorWithDescription(description);
    [strongConnector adapter:strongAdapter didFailAd:error];
    return;
  }
  _nativeAd.delegate = self;
  [FBAdSettings
      setMediationService:[NSString stringWithFormat:@"ADMOB_%@", [GADRequest sdkVersion]]];
  [_nativeAd loadAd];
}

- (void)stopBeingDelegate {
  _nativeAd.delegate = nil;
  _mediaView.delegate = nil;
}

- (void)loadAdChoicesView {
  if (!_adOptionsView) {
      _adOptionsView = [[FBAdOptionsView alloc] init];
      _adOptionsView.backgroundColor = [UIColor clearColor];
      
      NSLayoutConstraint *height = [NSLayoutConstraint
                                    constraintWithItem:_adOptionsView
                                    attribute:NSLayoutAttributeHeight
                                    relatedBy:NSLayoutRelationEqual
                                    toItem:nil
                                    attribute:NSLayoutAttributeNotAnAttribute
                                    multiplier:0
                                    constant:FBAdOptionsViewHeight];
      NSLayoutConstraint *width = [NSLayoutConstraint
                                   constraintWithItem:_adOptionsView
                                   attribute:NSLayoutAttributeWidth
                                   relatedBy:NSLayoutRelationEqual
                                   toItem:nil
                                   attribute:NSLayoutAttributeNotAnAttribute
                                   multiplier:0
                                   constant:FBAdOptionsViewWidth];
      [_adOptionsView addConstraint:height];
      [_adOptionsView addConstraint:width];
      [_adOptionsView updateConstraints];
  }
}

#pragma mark - GADMediatedNativeAd

- (id<GADMediatedNativeAdDelegate>)mediatedNativeAdDelegate {
  return self;
}

- (NSDictionary *)extraAssets {
  NSDictionary *__block extraAssets = nil;
  dispatch_sync(_lockQueue, ^{
    if (self->_extraAssets) {
      extraAssets = [self->_extraAssets copy];
    } else {
      NSMutableDictionary *mutableExtraAssets = [[NSMutableDictionary alloc] init];
      NSString *socialContext = [self->_nativeAd.socialContext copy];
      if (socialContext) {
        mutableExtraAssets[GADFBSocialContext] = socialContext;
      }

      extraAssets = mutableExtraAssets;
      self->_extraAssets = mutableExtraAssets;
    }
  });
  return extraAssets;
}

#pragma mark - GADMediatedNativeAppInstallAd

- (NSString *)headline {
  NSString *__block headline = nil;
  dispatch_sync(_lockQueue, ^{
    headline = [self->_nativeAd.headline copy];
  });
  return headline;
}

- (NSArray *)images {
  return nil;
}

- (NSString *)body {
  NSString *__block body = nil;
  dispatch_sync(_lockQueue, ^{
    body = [self->_nativeAd.bodyText copy];
  });
  return body;
}

- (GADNativeAdImage *)icon {
  GADNativeAdImage *__block icon = nil;
  UIGraphicsBeginImageContextWithOptions(CGSizeMake(1, 1), NO, 0.0);
  UIImage *blank = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  dispatch_sync(_lockQueue, ^{
    icon = [[GADNativeAdImage alloc] initWithImage:blank];
  });
  return icon;
}

- (NSString *)callToAction {
  NSString *__block callToAction = nil;
  dispatch_sync(_lockQueue, ^{
    callToAction = [self->_nativeAd.callToAction copy];
  });
  return callToAction;
}

- (NSDecimalNumber *)starRating {
  return nil;
}

- (NSString *)store {
  return nil;
}

- (NSString *)price {
  return nil;
}

/// Media view.
- (UIView *GAD_NULLABLE_TYPE)mediaView {
  return _mediaView;
}

- (UIView *GAD_NULLABLE_TYPE)adChoicesView {
  return _adOptionsView;
}

/// Returns YES if the ad has video content.
/// Because the FAN SDK doesn't offer a way to determine whether a native ad contains a
/// video asset or not, the adapter always returns a MediaView and claims to have video content.
- (BOOL)hasVideoContent {
  return YES;
}

#pragma mark - GADMediatedNativeAdDelegate

- (void)mediatedNativeAd:(id<GADMediatedNativeAd>)mediatedNativeAd
           didRenderInView:(UIView *)view
       clickableAssetViews:(NSDictionary<NSString *, UIView *> *)clickableAssetViews
    nonclickableAssetViews:(NSDictionary<NSString *, UIView *> *)nonclickableAssetViews
            viewController:(UIViewController *)viewController {
  NSArray *assets = clickableAssetViews.allValues;
  UIView *iconView;

  if ([view isKindOfClass:[GADNativeAppInstallAdView class]]) {
    iconView = [clickableAssetViews valueForKey:GADNativeAdIconView];
  }

  if (assets.count > 0 && iconView) {
    [_nativeAd registerViewForInteraction:view
                                mediaView:_mediaView
                            iconImageView:iconView
                           viewController:viewController
                           clickableViews:assets];
  } else {
    [_nativeAd registerViewForInteraction:view
                                mediaView:_mediaView
                            iconImageView:iconView
                           viewController:viewController];
  }
  _adOptionsView.nativeAd = _nativeAd;
}

- (void)mediatedNativeAd:(id<GADMediatedNativeAd>)mediatedNativeAd didUntrackView:(UIView *)view {
  [_adOptionsView removeFromSuperview];
  [_nativeAd unregisterView];
}

#pragma mark - FBNativeAdDelegate

- (void)nativeAdDidLoad:(FBNativeAd *)nativeAd {
  _mediaView = [[FBMediaView alloc] init];
  _mediaView.delegate = self;
  [self loadAdChoicesView];
  id<GADMAdNetworkAdapter> strongAdapter = self->_adapter;
  id<GADMAdNetworkConnector> strongConnector = self->_connector;
  [strongConnector adapter:strongAdapter didReceiveMediatedNativeAd:self];
}

- (void)nativeAdWillLogImpression:(FBNativeAd *)nativeAd {
  if (_impressionLogged) {
    GADFB_LOG(@"FBNativeAd is trying to log an impression again. Adapter will ignore duplicate "
               "impression pings.");
    return;
  }

  _impressionLogged = YES;
  [GADMediatedNativeAdNotificationSource mediatedNativeAdDidRecordImpression:self];
}

- (void)nativeAd:(FBNativeAd *)nativeAd didFailWithError:(NSError *)error {
  id<GADMAdNetworkConnector> strongConnector = _connector;
  id<GADMAdNetworkAdapter> strongAdapter = _adapter;
  [strongConnector adapter:strongAdapter didFailAd:error];
}

- (void)nativeAdDidClick:(FBNativeAd *)nativeAd {
  [GADMediatedNativeAdNotificationSource mediatedNativeAdDidRecordClick:self];
}

- (void)nativeAdDidFinishHandlingClick:(FBNativeAd *)nativeAd {
  // Do nothing.
}

#pragma mark - FBMediaViewDelegate

- (void)mediaViewVideoDidComplete:(FBMediaView *)mediaView {
  [GADMediatedNativeAdNotificationSource mediatedNativeAdDidEndVideoPlayback:self];
}

- (void)mediaViewVideoDidPlay:(FBMediaView *)mediaView {
  [GADMediatedNativeAdNotificationSource mediatedNativeAdDidPlayVideo:self];
}

- (void)mediaViewVideoDidPause:(FBMediaView *)mediaView {
  [GADMediatedNativeAdNotificationSource mediatedNativeAdDidPauseVideo:self];
}

- (void)mediaViewDidLoad:(FBMediaView *)mediaView {
  // Do nothing.
}

@end
