//
//  RMMapView.m
//  MapView
//
//  Created by David Bainbridge on 2/17/13.
//
//

#import "RMMapView.h"
#import "RMMapViewDelegate.h"
#import "RMPixel.h"

#import "RMFoundation.h"
#import "RMProjection.h"
#import "RMMarker.h"
#import "RMCircle.h"
#import "RMShape.h"
#import "RMAnnotation.h"
#import "RMQuadTree.h"

#import "RMFractalTileProjection.h"

#import "RMTileCacheMulti.h"
#import "RMTileSource.h"
#import "RMMapBoxSource.h"

#import "RMMapTiledLayerView.h"
#import "RMMapOverlayView.h"
#import "RMLoadingTileView.h"

#import "RMUserLocation.h"

#import "RMAttributionViewController.h"

#import "DuxScrollViewAnimation.h"

//#import "SMCalloutView.h"

#pragma mark --- begin constants ----

#define kZoomRectPixelBuffer 150.0

#define kDefaultInitialLatitude  38.913175
#define kDefaultInitialLongitude -77.032458

#define kDefaultMinimumZoomLevel 0.0
#define kDefaultMaximumZoomLevel 25.0
#define kDefaultInitialZoomLevel 11.0

#define kRMTrackingHaloAnnotationTypeName   @"RMTrackingHaloAnnotation"
#define kRMAccuracyCircleAnnotationTypeName @"RMAccuracyCircleAnnotation"

#pragma mark --- end constants ----

@interface RMMapView (PrivateMethods) < RMMapScrollViewDelegate, CLLocationManagerDelegate>

@property (nonatomic, assign) NSViewController *viewControllerPresentingAttribution;
@property (nonatomic, retain) RMUserLocation *userLocation;

- (void)createMapView;

- (void)registerMoveEventByUser:(BOOL)wasUserEvent;
- (void)completeMoveEventAfterDelay:(NSTimeInterval)delay;
- (void)registerZoomEventByUser:(BOOL)wasUserEvent;
- (void)completeZoomEventAfterDelay:(NSTimeInterval)delay;

- (void)correctPositionOfAllAnnotations;
- (void)correctPositionOfAllAnnotationsIncludingInvisibles:(BOOL)correctAllLayers animated:(BOOL)animated;
- (void)correctOrderingOfAllAnnotations;

- (void)updateHeadingForDeviceOrientation;

@end

#pragma mark -

@interface RMUserLocation (PrivateMethods)

@property (nonatomic, getter=isUpdating) BOOL updating;
@property (nonatomic, retain) CLLocation *location;
@property (nonatomic, retain) CLHeading *heading;
@property (nonatomic, assign) BOOL hasCustomLayer;

@end

#pragma mark -

@interface RMAnnotation (PrivateMethods)

@property (nonatomic, assign) BOOL isUserLocationAnnotation;

@end

#pragma mark -

@interface RMMapView ()

@property (nonatomic, assign) NSPoint clickPoint;
@property (nonatomic, assign) NSPoint originalOrigin;
@end

@implementation RMMapView
{
    __weak id <RMMapViewDelegate> _delegate;
    struct {
        unsigned int beforeMapMove:1;
        unsigned int afterMapMove:1;
        unsigned int beforeMapZoom:1;
        unsigned int afterMapZoom:1;
        unsigned int mapViewRegionDidChange:1;
        unsigned int doubleTapOnMap:1;
        unsigned int singleTapOnMap:1;
        unsigned int singleTapTwoFingersOnMap:1;
        unsigned int longPressOnMap:1;
        unsigned int tapOnAnnotation:1;
        unsigned int doubleTapOnAnnotation:1;
        unsigned int longPressOnAnnotation:1;
        unsigned int tapOnCalloutAccessoryControlForAnnotation:1;
        unsigned int tapOnLabelForAnnotation:1;
        unsigned int doubleTapOnLabelForAnnotation:1;
        unsigned int shouldDragMarker:1;
        unsigned int didDragMarker:1;
        unsigned int didEndDragMarker:1;
        unsigned int layerForAnnotation:1;
        unsigned int willHideLayerForAnnotation:1;
        unsigned int didHideLayerForAnnotation:1;
        unsigned int willStartLocatingUser:1;
        unsigned int didStopLocatingUser:1;
        unsigned int didUpdateUserLocation:1;
        unsigned int didFailToLocateUserWithError:1;
        unsigned int didChangeUserTrackingMode:1;
        
    } delegateRespondsTo;
    
    NSView *_backgroundView;
    RMMapScrollView *_mapScrollView;
    RMMapOverlayView *_overlayView;
    NSView *_tiledLayersSuperview;
    RMLoadingTileView *_loadingTileView;
    
    RMProjection *_projection;
    RMFractalTileProjection *_mercatorToTileProjection;
    RMTileSourcesContainer *_tileSourcesContainer;
    
    NSMutableSet *_annotations;
    NSMutableSet *_visibleAnnotations;
    
    BOOL _constrainMovement, _constrainMovementByUser;
    RMProjectedRect _constrainingProjectedBounds, _constrainingProjectedBoundsByUser;
  
    double _metersPerPixel;
    float _zoom, _lastZoom;
    CGPoint _lastContentOffset, _accumulatedDelta;
    CGSize _lastContentSize;
    BOOL _mapScrollViewIsZooming;
    
    BOOL _draggingEnabled, _bouncingEnabled;
    
    CGPoint _lastDraggingTranslation;
    RMAnnotation *_draggedAnnotation;
    
    CLLocationManager *_locationManager;
    
    RMAnnotation *_accuracyCircleAnnotation;
    RMAnnotation *_trackingHaloAnnotation;
    
    NSImageView *_userLocationTrackingView;
    NSImageView *_userHeadingTrackingView;
    NSImageView *_userHaloTrackingView;
    
    NSViewController *_viewControllerPresentingAttribution;
    NSButton *_attributionButton;
    
    CGAffineTransform _mapTransform;
    CATransform3D _annotationTransform;
    
    NSOperationQueue *_moveDelegateQueue;
    NSOperationQueue *_zoomDelegateQueue;
    
    NSImageView *_logoBug;
    
    RMAnnotation *_currentAnnotation;
//    SMCalloutView *_currentCallout;
    
    BOOL _rotateAtMinZoom;
}

@synthesize decelerationMode = _decelerationMode;

@synthesize zoomingInPivotsAroundCenter = _zoomingInPivotsAroundCenter;
@synthesize minZoom = _minZoom, maxZoom = _maxZoom;
@synthesize screenScale = _screenScale;
@synthesize tileCache = _tileCache;
@synthesize quadTree = _quadTree;
@synthesize clusteringEnabled = _clusteringEnabled;
@synthesize positionClusterMarkersAtTheGravityCenter = _positionClusterMarkersAtTheGravityCenter;
@synthesize orderMarkersByYPosition = _orderMarkersByYPosition;
@synthesize orderClusterMarkersAboveOthers = _orderClusterMarkersAboveOthers;
@synthesize clusterMarkerSize = _clusterMarkerSize, clusterAreaSize = _clusterAreaSize;
@synthesize adjustTilesForRetinaDisplay = _adjustTilesForRetinaDisplay;
@synthesize userLocation = _userLocation;
@synthesize showsUserLocation = _showsUserLocation;
@synthesize userTrackingMode = _userTrackingMode;
@synthesize displayHeadingCalibration = _displayHeadingCalibration;
@synthesize debugTiles = _debugTiles;
@synthesize hideAttribution = _hideAttribution;
@synthesize showLogoBug = _showLogoBug;


#pragma mark -
#pragma mark Initialization

- (void)performInitializationWithTilesource:(RMTileSource *)newTilesource
                           centerCoordinate:(CLLocationCoordinate2D)initialCenterCoordinate
                                  zoomLevel:(float)initialTileSourceZoomLevel
                               maxZoomLevel:(float)initialTileSourceMaxZoomLevel
                               minZoomLevel:(float)initialTileSourceMinZoomLevel
                            backgroundImage:(NSImage *)backgroundImage
{
    _constrainMovement = _constrainMovementByUser = _bouncingEnabled = _zoomingInPivotsAroundCenter = NO;
    _draggingEnabled = YES;
    
    _lastDraggingTranslation = CGPointZero;
    _draggedAnnotation = nil;
 
    // TODO: FIXME
    //self.backgroundColor = [UIColor grayColor];
    
    // TODO: FIXME
    //self.clipsToBounds = YES;
    
    _tileSourcesContainer = [RMTileSourcesContainer new];
    _tiledLayersSuperview = nil;
    
    _projection = nil;
    _mercatorToTileProjection = nil;
    _mapScrollView = nil;
    _overlayView = nil;
    
    _screenScale = [NSScreen mainScreen].backingScaleFactor;
    
    _adjustTilesForRetinaDisplay = YES;
    _debugTiles = NO;
    
    _orderMarkersByYPosition = YES;
    _orderClusterMarkersAboveOthers = YES;

    _annotations = [NSMutableSet new];
    _visibleAnnotations = [NSMutableSet new];
    [self setQuadTree:[[RMQuadTree alloc] initWithMapView:self]];
    _clusteringEnabled = NO;
    _positionClusterMarkersAtTheGravityCenter = YES;
    _clusterMarkerSize = CGSizeMake(100.0, 100.0);
    _clusterAreaSize = CGSizeMake(150.0, 150.0);
    
    _metersPerPixel = 1.0;
    
    _moveDelegateQueue = [NSOperationQueue new];
    [_moveDelegateQueue setMaxConcurrentOperationCount:1];
    
    _zoomDelegateQueue = [NSOperationQueue new];
    [_zoomDelegateQueue setMaxConcurrentOperationCount:1];
    
    [self setTileCache:[RMTileCacheMulti new]];
    
    if (backgroundImage)
    {
        [self setBackgroundView:[[NSView alloc] initWithFrame:[self bounds]]];
        self.backgroundView.layer.contents = (id)backgroundImage.CGImage;
    }
    else
    {
        _loadingTileView = [[RMLoadingTileView alloc] initWithFrame:self.bounds];
        [self setBackgroundView:_loadingTileView];
    }
    
    if (initialTileSourceMinZoomLevel < newTilesource.minZoom)
        initialTileSourceMinZoomLevel = newTilesource.minZoom;
    if (initialTileSourceMaxZoomLevel > newTilesource.maxZoom)
        initialTileSourceMaxZoomLevel = newTilesource.maxZoom;
    
    [self setTileSourcesMinZoom:initialTileSourceMinZoomLevel];
    [self setTileSourcesMaxZoom:initialTileSourceMaxZoomLevel];
    [self setTileSourcesZoom:initialTileSourceZoomLevel];
    
    [self setTileSource:newTilesource];
    [self setCenterCoordinate:initialCenterCoordinate animated:NO];
    
    [self setDecelerationMode:RMMapDecelerationFast];
    
    self.showLogoBug = YES;
    
    self.displayHeadingCalibration = YES;
    
    _mapTransform = CGAffineTransformIdentity;
    _annotationTransform = CATransform3DIdentity;
    
   
    // TODO: Check
    /*
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleMemoryWarningNotification:)
                                                 name:UIApplicationDidReceiveMemoryWarningNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleWillChangeOrientationNotification:)
                                                 name:UIApplicationWillChangeStatusBarOrientationNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleDidChangeOrientationNotification:)
                                                 name:UIApplicationDidChangeStatusBarOrientationNotification
                                               object:nil];
 */   
    RMLog(@"Map initialised. tileSource:%@, minZoom:%f, maxZoom:%f, zoom:%f at {%f,%f}", newTilesource, self.minZoom, self.maxZoom, self.zoom, initialCenterCoordinate.longitude, initialCenterCoordinate.latitude);
}

- (id)initWithCoder:(NSCoder *)aDecoder
{
    if (!(self = [super initWithCoder:aDecoder]))
        return nil;
    
	CLLocationCoordinate2D coordinate;
	coordinate.latitude = kDefaultInitialLatitude;
	coordinate.longitude = kDefaultInitialLongitude;
    
    [self performInitializationWithTilesource:[RMMapBoxSource new]
                             centerCoordinate:coordinate
                                    zoomLevel:kDefaultInitialZoomLevel
                                 maxZoomLevel:kDefaultMaximumZoomLevel
                                 minZoomLevel:kDefaultMinimumZoomLevel
                              backgroundImage:nil];
    
    return self;
}

- (id)initWithFrame:(CGRect)frame
{
    return [self initWithFrame:frame andTilesource:[RMMapBoxSource new]];
}

- (id)initWithFrame:(CGRect)frame andTilesource:(RMTileSource *)newTilesource
{
	CLLocationCoordinate2D coordinate;
	coordinate.latitude = kDefaultInitialLatitude;
	coordinate.longitude = kDefaultInitialLongitude;
    
	return [self initWithFrame:frame
                 andTilesource:newTilesource
              centerCoordinate:coordinate
                     zoomLevel:kDefaultInitialZoomLevel
                  maxZoomLevel:kDefaultMaximumZoomLevel
                  minZoomLevel:kDefaultMinimumZoomLevel
               backgroundImage:nil];
}

- (id)initWithFrame:(CGRect)frame
      andTilesource:(RMTileSource *)newTilesource
   centerCoordinate:(CLLocationCoordinate2D)initialCenterCoordinate
          zoomLevel:(float)initialZoomLevel
       maxZoomLevel:(float)maxZoomLevel
       minZoomLevel:(float)minZoomLevel
    backgroundImage:(NSImage *)backgroundImage
{
    if (!newTilesource || !(self = [super initWithFrame:frame]))
        return nil;
    
    [self performInitializationWithTilesource:newTilesource
                             centerCoordinate:initialCenterCoordinate
                                    zoomLevel:initialZoomLevel
                                 maxZoomLevel:maxZoomLevel
                                 minZoomLevel:minZoomLevel
                              backgroundImage:backgroundImage];
    
    return self;
}

- (void)setFrame:(CGRect)frame
{
    CGRect r = self.frame;
    [super setFrame:frame];
    return;
    
    // only change if the frame changes and not during initialization
    if ( ! CGRectEqualToRect(r, frame))
    {
        RMProjectedPoint centerPoint = self.centerProjectedPoint;
        
        CGRect bounds = CGRectMake(0, 0, frame.size.width, frame.size.height);
        _backgroundView.frame = bounds;
        _mapScrollView.frame = bounds;
        _overlayView.frame = bounds;
        
        [self setCenterProjectedPoint:centerPoint animated:NO];
        
        [self correctPositionOfAllAnnotations];
        
        self.minZoom = 0; // force new minZoom calculation
        
        if (_loadingTileView)
            _loadingTileView.mapZooming = NO;
    }
}

+ (NSImage *)resourceImageNamed:(NSString *)imageName
{
    /*
    NSAssert([[NSBundle mainBundle] pathForResource:@"MapBox" ofType:@"bundle"], @"Resource bundle not found in application.");
    
    if ( ! [[imageName pathExtension] length])
        imageName = [imageName stringByAppendingString:@".png"];
    
    NSString *bundlePath = [[NSBundle mainBundle] pathForResource:@"MapBox" ofType:@"bundle"];
    NSBundle *resourcesBundle = [NSBundle bundleWithPath:bundlePath];
     */
    NSString *imagePath = [[NSBundle mainBundle] pathForResource:imageName ofType:nil];
    
    return [NSImage imageWithContentsOfFile:imagePath];
}

- (void)dealloc
{
    [_moveDelegateQueue cancelAllOperations];
    [_zoomDelegateQueue cancelAllOperations];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_mapScrollView removeObserver:self forKeyPath:@"contentOffset"];
    [_tileSourcesContainer cancelAllDownloads];
    _locationManager.delegate = nil;
    [_locationManager stopUpdatingLocation];
    //[_locationManager stopUpdatingHeading];
}

- (void)didReceiveMemoryWarning
{
    LogMethod();
    
    [self.tileCache didReceiveMemoryWarning];
    [self.tileSourcesContainer didReceiveMemoryWarning];
}

- (void)handleMemoryWarningNotification:(NSNotification *)notification
{
	[self didReceiveMemoryWarning];
}

// TODO: verify orientation
/* 
- (void)handleWillChangeOrientationNotification:(NSNotification *)notification
{
    // send a dummy heading update to force re-rotation
    //
    if (self.userTrackingMode == RMUserTrackingModeFollowWithHeading)
        [self locationManager:_locationManager didUpdateHeading:_locationManager.heading];
    
    // fix UIScrollView artifacts from rotation at minZoomScale
    //
    _rotateAtMinZoom = fabs(self.zoom - self.minZoom) < 0.1;
}

- (void)handleDidChangeOrientationNotification:(NSNotification *)notification
{
    if (_rotateAtMinZoom)
        [_mapScrollView setZoomScale:_mapScrollView.minimumZoomScale animated:YES];
    
    [self updateHeadingForDeviceOrientation];
}
*/
- (void)layoutSubviews
{
    self.viewControllerPresentingAttribution = nil;
    // TODO: FIXME
#if 0
    if ( ! self.viewControllerPresentingAttribution && ! _hideAttribution)
    {
        NSViewController *candidateViewController = self.window.rootViewController;
        
        while ([self isDescendantOfView:candidateViewController.view])
        {
            for (NSViewController *childViewController in candidateViewController.childViewControllers)
                if ([self isDescendantOfView:childViewController.view])
                    candidateViewController = childViewController;
            
            if ( ! [candidateViewController.childViewControllers count] || [candidateViewController isEqual:self.window.rootViewController])
                break;
        }
        
        self.viewControllerPresentingAttribution = candidateViewController;
    }
    else if (self.viewControllerPresentingAttribution && _hideAttribution)
    {
        self.viewControllerPresentingAttribution = nil;
    }
#endif
   // [super layoutSubviews];
}

- (void)removeFromSuperview
{
    self.viewControllerPresentingAttribution = nil;
    
    [super removeFromSuperview];
}

- (NSString *)description
{
	CGRect bounds = self.bounds;
    
	return [NSString stringWithFormat:@"MapView at {%.0f,%.0f}-{%.0fx%.0f}", bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height];
}

#pragma mark -
#pragma mark Delegate

- (id <RMMapViewDelegate>)delegate
{
	return _delegate;
}

- (void)setDelegate:(id <RMMapViewDelegate>)aDelegate
{
    if (_delegate == aDelegate)
        return;
    
    _delegate = aDelegate;
    
    delegateRespondsTo.beforeMapMove = [_delegate respondsToSelector:@selector(beforeMapMove:byUser:)];
    delegateRespondsTo.afterMapMove  = [_delegate respondsToSelector:@selector(afterMapMove:byUser:)];
    
    delegateRespondsTo.beforeMapZoom = [_delegate respondsToSelector:@selector(beforeMapZoom:byUser:)];
    delegateRespondsTo.afterMapZoom  = [_delegate respondsToSelector:@selector(afterMapZoom:byUser:)];
    
    delegateRespondsTo.mapViewRegionDidChange = [_delegate respondsToSelector:@selector(mapViewRegionDidChange:)];
    
    delegateRespondsTo.doubleTapOnMap = [_delegate respondsToSelector:@selector(doubleTapOnMap:at:)];
    delegateRespondsTo.singleTapOnMap = [_delegate respondsToSelector:@selector(singleTapOnMap:at:)];
    delegateRespondsTo.singleTapTwoFingersOnMap = [_delegate respondsToSelector:@selector(singleTapTwoFingersOnMap:at:)];
    delegateRespondsTo.longPressOnMap = [_delegate respondsToSelector:@selector(longPressOnMap:at:)];
    
    delegateRespondsTo.tapOnAnnotation = [_delegate respondsToSelector:@selector(tapOnAnnotation:onMap:)];
    delegateRespondsTo.doubleTapOnAnnotation = [_delegate respondsToSelector:@selector(doubleTapOnAnnotation:onMap:)];
    delegateRespondsTo.longPressOnAnnotation = [_delegate respondsToSelector:@selector(longPressOnAnnotation:onMap:)];
    delegateRespondsTo.tapOnCalloutAccessoryControlForAnnotation = [_delegate respondsToSelector:@selector(tapOnCalloutAccessoryControl:forAnnotation:onMap:)];
    delegateRespondsTo.tapOnLabelForAnnotation = [_delegate respondsToSelector:@selector(tapOnLabelForAnnotation:onMap:)];
    delegateRespondsTo.doubleTapOnLabelForAnnotation = [_delegate respondsToSelector:@selector(doubleTapOnLabelForAnnotation:onMap:)];
    
    delegateRespondsTo.shouldDragMarker = [_delegate respondsToSelector:@selector(mapView:shouldDragAnnotation:)];
    delegateRespondsTo.didDragMarker = [_delegate respondsToSelector:@selector(mapView:didDragAnnotation:withDelta:)];
    delegateRespondsTo.didEndDragMarker = [_delegate respondsToSelector:@selector(mapView:didEndDragAnnotation:)];
    
    delegateRespondsTo.layerForAnnotation = [_delegate respondsToSelector:@selector(mapView:layerForAnnotation:)];
    delegateRespondsTo.willHideLayerForAnnotation = [_delegate respondsToSelector:@selector(mapView:willHideLayerForAnnotation:)];
    delegateRespondsTo.didHideLayerForAnnotation = [_delegate respondsToSelector:@selector(mapView:didHideLayerForAnnotation:)];
    
    delegateRespondsTo.willStartLocatingUser = [_delegate respondsToSelector:@selector(mapViewWillStartLocatingUser:)];
    delegateRespondsTo.didStopLocatingUser = [_delegate respondsToSelector:@selector(mapViewDidStopLocatingUser:)];
    delegateRespondsTo.didUpdateUserLocation = [_delegate respondsToSelector:@selector(mapView:didUpdateUserLocation:)];
    delegateRespondsTo.didFailToLocateUserWithError = [_delegate respondsToSelector:@selector(mapView:didFailToLocateUserWithError:)];
    delegateRespondsTo.didChangeUserTrackingMode = [_delegate respondsToSelector:@selector(mapView:didChangeUserTrackingMode:animated:)];
}

- (void)registerMoveEventByUser:(BOOL)wasUserEvent
{
    @synchronized (_moveDelegateQueue)
    {
        BOOL flag = wasUserEvent;
        
        if ([_moveDelegateQueue operationCount] == 0)
        {
            dispatch_async(dispatch_get_main_queue(), ^(void)
                           {
                               if (delegateRespondsTo.beforeMapMove)
                                   [_delegate beforeMapMove:self byUser:flag];
                           });
        }
        
        [_moveDelegateQueue setSuspended:YES];
        
        if ([_moveDelegateQueue operationCount] == 0)
        {
            [_moveDelegateQueue addOperationWithBlock:^(void)
             {
                 dispatch_async(dispatch_get_main_queue(), ^(void)
                                {
                                    if (delegateRespondsTo.afterMapMove)
                                        [_delegate afterMapMove:self byUser:flag];
                                });
             }];
        }
    }
}

- (void)completeMoveEventAfterDelay:(NSTimeInterval)delay
{
    [_moveDelegateQueue performSelector:@selector(setSuspended:) withObject:[NSNumber numberWithBool:NO] afterDelay:delay];
}

- (void)registerZoomEventByUser:(BOOL)wasUserEvent
{
    @synchronized (_zoomDelegateQueue)
    {
        BOOL flag = wasUserEvent;
        
        if ([_zoomDelegateQueue operationCount] == 0)
        {
            dispatch_async(dispatch_get_main_queue(), ^(void)
                           {
                               if (delegateRespondsTo.beforeMapZoom)
                                   [_delegate beforeMapZoom:self byUser:flag];
                           });
        }
        
        [_zoomDelegateQueue setSuspended:YES];
        
        if ([_zoomDelegateQueue operationCount] == 0)
        {
            [_zoomDelegateQueue addOperationWithBlock:^(void)
             {
                 dispatch_async(dispatch_get_main_queue(), ^(void)
                                {
                                    if (delegateRespondsTo.afterMapZoom)
                                        [_delegate afterMapZoom:self byUser:flag];
                                });
             }];
        }
    }
}

- (void)completeZoomEventAfterDelay:(NSTimeInterval)delay
{
    [_zoomDelegateQueue performSelector:@selector(setSuspended:) withObject:[NSNumber numberWithBool:NO] afterDelay:delay];
}

#pragma mark -
#pragma mark Bounds

- (RMProjectedRect)fitProjectedRect:(RMProjectedRect)rect1 intoRect:(RMProjectedRect)rect2
{
    if (rect1.size.width > rect2.size.width || rect1.size.height > rect2.size.height)
        return rect2;
    
    RMProjectedRect fittedRect = RMProjectedRectMake(0.0, 0.0, rect1.size.width, rect1.size.height);
    
    if (rect1.origin.x < rect2.origin.x)
        fittedRect.origin.x = rect2.origin.x;
    else if (rect1.origin.x + rect1.size.width > rect2.origin.x + rect2.size.width)
        fittedRect.origin.x = (rect2.origin.x + rect2.size.width) - rect1.size.width;
    else
        fittedRect.origin.x = rect1.origin.x;
    
    if (rect1.origin.y < rect2.origin.y)
        fittedRect.origin.y = rect2.origin.y;
    else if (rect1.origin.y + rect1.size.height > rect2.origin.y + rect2.size.height)
        fittedRect.origin.y = (rect2.origin.y + rect2.size.height) - rect1.size.height;
    else
        fittedRect.origin.y = rect1.origin.y;
    
    return fittedRect;
}

- (RMProjectedRect)projectedRectFromLatitudeLongitudeBounds:(RMSphericalTrapezium)bounds
{
    CLLocationCoordinate2D southWest = bounds.southWest;
    CLLocationCoordinate2D northEast = bounds.northEast;
    CLLocationCoordinate2D midpoint = {
        .latitude = (northEast.latitude + southWest.latitude) / 2,
        .longitude = (northEast.longitude + southWest.longitude) / 2
    };
    
    RMProjectedPoint myOrigin = [_projection coordinateToProjectedPoint:midpoint];
    RMProjectedPoint southWestPoint = [_projection coordinateToProjectedPoint:southWest];
    RMProjectedPoint northEastPoint = [_projection coordinateToProjectedPoint:northEast];
    RMProjectedPoint myPoint = {
        .x = northEastPoint.x - southWestPoint.x,
        .y = northEastPoint.y - southWestPoint.y
    };
    
    // Create the new zoom layout
    RMProjectedRect zoomRect;
    
    // Default is with scale = 2.0 * mercators/pixel
    zoomRect.size.width = self.bounds.size.width * 2.0;
    zoomRect.size.height = self.bounds.size.height * 2.0;
    
    if ((myPoint.x / self.bounds.size.width) < (myPoint.y / self.bounds.size.height))
    {
        if ((myPoint.y / self.bounds.size.height) > 1)
        {
            zoomRect.size.width = self.bounds.size.width * (myPoint.y / self.bounds.size.height);
            zoomRect.size.height = self.bounds.size.height * (myPoint.y / self.bounds.size.height);
        }
    }
    else
    {
        if ((myPoint.x / self.bounds.size.width) > 1)
        {
            zoomRect.size.width = self.bounds.size.width * (myPoint.x / self.bounds.size.width);
            zoomRect.size.height = self.bounds.size.height * (myPoint.x / self.bounds.size.width);
        }
    }
    
    myOrigin.x = myOrigin.x - (zoomRect.size.width / 2);
    myOrigin.y = myOrigin.y - (zoomRect.size.height / 2);
    
    RMLog(@"Origin is calculated at: %f, %f", [_projection projectedPointToCoordinate:myOrigin].longitude, [_projection projectedPointToCoordinate:myOrigin].latitude);
    
    zoomRect.origin = myOrigin;
    
    return zoomRect;
}

- (BOOL)tileSourceBoundsContainProjectedPoint:(RMProjectedPoint)point
{
    RMSphericalTrapezium bounds = [self.tileSourcesContainer latitudeLongitudeBoundingBox];
    
    if (bounds.northEast.latitude == 90.0 && bounds.northEast.longitude == 180.0 &&
        bounds.southWest.latitude == -90.0 && bounds.southWest.longitude == -180.0)
    {
        return YES;
    }
    
    return RMProjectedRectContainsProjectedPoint(_constrainingProjectedBounds, point);
}

- (BOOL)tileSourceBoundsContainScreenPoint:(CGPoint)pixelCoordinate
{
    RMProjectedPoint projectedPoint = [self pixelToProjectedPoint:pixelCoordinate];
    
    return [self tileSourceBoundsContainProjectedPoint:projectedPoint];
}

// ===

- (void)setConstraintsSouthWest:(CLLocationCoordinate2D)southWest northEast:(CLLocationCoordinate2D)northEast
{
    RMProjectedPoint projectedSouthWest = [_projection coordinateToProjectedPoint:southWest];
    RMProjectedPoint projectedNorthEast = [_projection coordinateToProjectedPoint:northEast];
    
    [self setProjectedConstraintsSouthWest:projectedSouthWest northEast:projectedNorthEast];
}

- (void)setProjectedConstraintsSouthWest:(RMProjectedPoint)southWest northEast:(RMProjectedPoint)northEast
{
    _constrainMovement = _constrainMovementByUser = YES;
    _constrainingProjectedBounds = RMProjectedRectMake(southWest.x, southWest.y, northEast.x - southWest.x, northEast.y - southWest.y);
    _constrainingProjectedBoundsByUser = RMProjectedRectMake(southWest.x, southWest.y, northEast.x - southWest.x, northEast.y - southWest.y);
}

- (void)setTileSourcesConstraintsFromLatitudeLongitudeBoundingBox:(RMSphericalTrapezium)bounds
{
    BOOL tileSourcesConstrainMovement = !(bounds.northEast.latitude == 90.0 && bounds.northEast.longitude == 180.0 && bounds.southWest.latitude == -90.0 && bounds.southWest.longitude == -180.0);
    
    if (tileSourcesConstrainMovement)
    {
        _constrainMovement = YES;
        RMProjectedRect tileSourcesConstrainingProjectedBounds = [self projectedRectFromLatitudeLongitudeBounds:bounds];
        
        if (_constrainMovementByUser)
        {
            _constrainingProjectedBounds = RMProjectedRectIntersection(_constrainingProjectedBoundsByUser, tileSourcesConstrainingProjectedBounds);
            
            if (RMProjectedRectIsZero(_constrainingProjectedBounds))
                RMLog(@"The constraining bounds from tilesources and user don't intersect!");
        }
        else
            _constrainingProjectedBounds = tileSourcesConstrainingProjectedBounds;
    }
    else if (_constrainMovementByUser)
    {
        _constrainingProjectedBounds = _constrainingProjectedBoundsByUser;
    }
    else
    {
        _constrainingProjectedBounds = _projection.planetBounds;
    }
}

#pragma mark -
#pragma mark Movement

- (CLLocationCoordinate2D)centerCoordinate
{
    return [_projection projectedPointToCoordinate:[self centerProjectedPoint]];
}

- (void)setCenterCoordinate:(CLLocationCoordinate2D)centerCoordinate
{
    [self setCenterProjectedPoint:[_projection coordinateToProjectedPoint:centerCoordinate]];
}

- (void)setCenterCoordinate:(CLLocationCoordinate2D)centerCoordinate animated:(BOOL)animated
{
    [self setCenterProjectedPoint:[_projection coordinateToProjectedPoint:centerCoordinate] animated:animated];
}

// ===

- (RMProjectedPoint)centerProjectedPoint
{
    CGPoint center = CGPointMake(_mapScrollView.contentOffset.x + _mapScrollView.bounds.size.width/2.0, _mapScrollView.contentSize.height - (_mapScrollView.contentOffset.y + _mapScrollView.bounds.size.height/2.0));
    
    RMProjectedRect planetBounds = _projection.planetBounds;
    RMProjectedPoint normalizedProjectedPoint;
    double xx = fabs(planetBounds.origin.x);
    normalizedProjectedPoint.x = (center.x * _metersPerPixel);
//    RMLog(@"centerProjectedPoint1: {%f,%f}", normalizedProjectedPoint.x, normalizedProjectedPoint.y);
    normalizedProjectedPoint.x = (2.0 * _metersPerPixel);
//    RMLog(@"centerProjectedPoint2: {%f,%f}", normalizedProjectedPoint.x, normalizedProjectedPoint.y);
    double x2 = (center.x * _metersPerPixel);
    double x3 = x2 - xx;
    normalizedProjectedPoint.x = (double)(center.x * _metersPerPixel) - fabs(planetBounds.origin.x);
    normalizedProjectedPoint.y = (center.y * _metersPerPixel) - fabs(planetBounds.origin.y);
    
//    RMLog(@"centerProjectedPoint3: {%f,%f}", normalizedProjectedPoint.x, normalizedProjectedPoint.y);
//    RMLog(@"contentOFfset: %f, %f", _mapScrollView.contentOffset.x, _mapScrollView.contentOffset.y);
//    RMLog(@"contentSize: %f, %f", _mapScrollView.contentSize.width, _mapScrollView.contentSize.height);
    return normalizedProjectedPoint;
}

- (void)setCenterProjectedPoint:(RMProjectedPoint)centerProjectedPoint
{
    [self setCenterProjectedPoint:centerProjectedPoint animated:YES];
}

- (void)scrollClipView:(NSClipView *)aClipView toPoint:(NSPoint)aPoint
{
    
}
- (void)setCenterProjectedPoint:(RMProjectedPoint)centerProjectedPoint animated:(BOOL)animated
{
    if (RMProjectedPointEqualToProjectedPoint(centerProjectedPoint, [self centerProjectedPoint]))
        return;
    
    [self registerMoveEventByUser:NO];
    
    RMLog(@"Current contentSize: {%.0f,%.0f}, zoom: %f", _mapScrollView.contentSize.width, _mapScrollView.contentSize.height, self.zoom);
    
    RMProjectedRect planetBounds = _projection.planetBounds;
	RMProjectedPoint normalizedProjectedPoint;
	normalizedProjectedPoint.x = centerProjectedPoint.x + fabs(planetBounds.origin.x);
	normalizedProjectedPoint.y = centerProjectedPoint.y + fabs(planetBounds.origin.y);
    
    [_mapScrollView setContentOffset:CGPointMake(normalizedProjectedPoint.x / _metersPerPixel - _mapScrollView.bounds.size.width/2.0,
                                                 _mapScrollView.contentSize.height - ((normalizedProjectedPoint.y / _metersPerPixel) + _mapScrollView.bounds.size.height/2.0))
                            animated:animated];
    
    RMLog(@"setMapCenterProjectedPoint: {%f,%f} -> {%.0f,%.0f}", centerProjectedPoint.x, centerProjectedPoint.y, _mapScrollView.contentOffset.x, _mapScrollView.contentOffset.y);
    
    if ( ! animated)
        [self completeMoveEventAfterDelay:0];
    
    [self correctPositionOfAllAnnotations];
}

// ===

- (void)moveBy:(CGSize)delta
{
    [self registerMoveEventByUser:NO];
    
    CGPoint contentOffset = _mapScrollView.contentOffset;
    contentOffset.x += delta.width;
    contentOffset.y += delta.height;
    _mapScrollView.contentOffset = contentOffset;
    
    [self completeMoveEventAfterDelay:0];
}

#pragma mark -
#pragma mark Zoom

- (RMProjectedRect)projectedBounds
{
    CGPoint bottomLeft = CGPointMake(_mapScrollView.contentOffset.x,  (_mapScrollView.contentOffset.y));
    
    RMProjectedRect planetBounds = _projection.planetBounds;
    RMProjectedRect normalizedProjectedRect;
    normalizedProjectedRect.origin.x = (bottomLeft.x * _metersPerPixel) - fabs(planetBounds.origin.x);
    normalizedProjectedRect.origin.y = (bottomLeft.y * _metersPerPixel) - fabs(planetBounds.origin.y);
    normalizedProjectedRect.size.width = [self mapSize:_zoom - 1];
    normalizedProjectedRect.size.height = [self mapSize:_zoom - 1];
//    normalizedProjectedRect.size.width = _mapScrollView.contentView.frame.size.width * _metersPerPixel;
//    normalizedProjectedRect.size.height = _mapScrollView.contentView.frame.size.height * _metersPerPixel;
    
    return normalizedProjectedRect;
}

- (void)setProjectedBounds:(RMProjectedRect)boundsRect
{
    [self setProjectedBounds:boundsRect animated:YES];
}

- (void)setProjectedBounds:(RMProjectedRect)boundsRect animated:(BOOL)animated
{
    if (_constrainMovement)
        boundsRect = [self fitProjectedRect:boundsRect intoRect:_constrainingProjectedBounds];
    
    RMProjectedRect planetBounds = _projection.planetBounds;
	RMProjectedPoint normalizedProjectedPoint;
	normalizedProjectedPoint.x = boundsRect.origin.x + fabs(planetBounds.origin.x);
	normalizedProjectedPoint.y = boundsRect.origin.y + fabs(planetBounds.origin.y);
    
    float zoomScale = _mapScrollView.zoomScale;
    CGRect zoomRect = CGRectMake((normalizedProjectedPoint.x / _metersPerPixel) / zoomScale,
                                 ((planetBounds.size.height - normalizedProjectedPoint.y - boundsRect.size.height) / _metersPerPixel) / zoomScale,
                                 (boundsRect.size.width / _metersPerPixel) / zoomScale,
                                 (boundsRect.size.height / _metersPerPixel) / zoomScale);
    [_mapScrollView zoomToRect:zoomRect animated:animated];
}

- (BOOL)shouldZoomToTargetZoom:(float)targetZoom withZoomFactor:(float)zoomFactor
{
    // bools for syntactical sugar to understand the logic in the if statement below
    BOOL zoomAtMax = ([self zoom] == [self maxZoom]);
    BOOL zoomAtMin = ([self zoom] == [self minZoom]);
    BOOL zoomGreaterMin = ([self zoom] > [self minZoom]);
    BOOL zoomLessMax = ([self zoom] < [self maxZoom]);
    
    //zooming in zoomFactor > 1
    //zooming out zoomFactor < 1
    if ((zoomGreaterMin && zoomLessMax) || (zoomAtMax && zoomFactor<1) || (zoomAtMin && zoomFactor>1))
        return YES;
    else
        return NO;
}

- (void)setZoom:(float)newZoom animated:(BOOL)animated
{
    [self setZoom:newZoom atCoordinate:self.centerCoordinate animated:animated];
}

- (void)setZoom:(float)newZoom atCoordinate:(CLLocationCoordinate2D)newCenter animated:(BOOL)animated
{
    /*
    [UIView animateWithDuration:(animated ? 0.3 : 0.0)
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationCurveEaseInOut
                     animations:^(void)
     {
         [self setZoom:newZoom];
         [self setCenterCoordinate:newCenter animated:NO];
         
         self.userTrackingMode = RMUserTrackingModeNone;
     }
                     completion:nil];
*/
    [self setZoom:newZoom];
    [self setCenterCoordinate:newCenter animated:NO];
}

- (void)zoomByFactor:(float)zoomFactor near:(CGPoint)pivot animated:(BOOL)animated
{
    if (![self tileSourceBoundsContainScreenPoint:pivot])
        return;
    
    float zoomDelta = log2f(zoomFactor);
    float targetZoom = zoomDelta + [self zoom];
    
    if (targetZoom == [self zoom])
        return;
    
    // clamp zoom to remain below or equal to maxZoom after zoomAfter will be applied
    // Set targetZoom to maxZoom so the map zooms to its maximum
    if (targetZoom > [self maxZoom])
    {
        zoomFactor = exp2f([self maxZoom] - [self zoom]);
        targetZoom = [self maxZoom];
    }
    
    // clamp zoom to remain above or equal to minZoom after zoomAfter will be applied
    // Set targetZoom to minZoom so the map zooms to its maximum
    if (targetZoom < [self minZoom])
    {
        zoomFactor = 1/exp2f([self zoom] - [self minZoom]);
        targetZoom = [self minZoom];
    }
    
    if ([self shouldZoomToTargetZoom:targetZoom withZoomFactor:zoomFactor])
    {
//        [self centerMapAtPixelPoint:pivot];
//        [_mapScrollView zoomToScale:targetZoom];
        [self setZoom:targetZoom];
        [_mapScrollView zoomWithFactor:zoomFactor];
        //[self updateMetersPerPixel];
    }
    else
    {
        if ([self zoom] > [self maxZoom])
            [self setZoom:[self maxZoom]];
        if ([self zoom] < [self minZoom])
            [self setZoom:[self minZoom]];
    }
}

- (float)nextNativeZoomFactor
{
    float newZoom = fminf(floorf([self zoom] + 1.0), [self maxZoom]);
    
    return exp2f(newZoom - [self zoom]);
}

- (float)previousNativeZoomFactor
{
    float newZoom = fmaxf(floorf([self zoom] - 1.0), [self minZoom]);
    
    return exp2f(newZoom - [self zoom]);
}

- (void)zoomInToNextNativeZoomAt:(CGPoint)pivot
{
    [self zoomInToNextNativeZoomAt:pivot animated:NO];
}

- (void)zoomInToNextNativeZoomAt:(CGPoint)pivot animated:(BOOL)animated
{
    if (self.userTrackingMode != RMUserTrackingModeNone && ! CGPointEqualToPoint(pivot, [self coordinateToPixel:self.userLocation.location.coordinate]))
        self.userTrackingMode = RMUserTrackingModeNone;
    
    // Calculate rounded zoom
    float newZoom = fmin(ceilf([self zoom]) + 1.0, [self maxZoom]);
    
    float factor = exp2f(newZoom - [self zoom]);
    
    if (factor > 2.25)
    {
        newZoom = fmin(ceilf([self zoom]), [self maxZoom]);
        factor = exp2f(newZoom - [self zoom]);
    }
    
    RMLog(@"zoom in from:%f to:%f by factor:%f around {%f,%f}", [self zoom], newZoom, factor, pivot.x, pivot.y);
    [self zoomByFactor:factor near:pivot animated:animated];
}

- (void)zoomOutToNextNativeZoomAt:(CGPoint)pivot
{
    [self zoomOutToNextNativeZoomAt:pivot animated:NO];
}

- (void)zoomOutToNextNativeZoomAt:(CGPoint)pivot animated:(BOOL) animated
{
    // Calculate rounded zoom
    float newZoom = fmax(floorf([self zoom]), [self minZoom]);
    
    float factor = exp2f(newZoom - [self zoom]);
    
    if (factor > 0.75)
    {
        newZoom = fmax(floorf([self zoom]) - 1.0, [self minZoom]);
        factor = exp2f(newZoom - [self zoom]);
    }
    
    RMLog(@"zoom out from:%f to:%f by factor:%f around {%f,%f}", [self zoom], newZoom, factor, pivot.x, pivot.y);
    [self zoomByFactor:factor near:pivot animated:animated];
}

#pragma mark -
#pragma mark Zoom With Bounds

- (void)zoomWithLatitudeLongitudeBoundsSouthWest:(CLLocationCoordinate2D)southWest northEast:(CLLocationCoordinate2D)northEast animated:(BOOL)animated
{
    if (northEast.latitude == southWest.latitude && northEast.longitude == southWest.longitude) // There are no bounds, probably only one marker.
    {
        RMProjectedRect zoomRect;
        RMProjectedPoint myOrigin = [_projection coordinateToProjectedPoint:southWest];
        
        // Default is with scale = 2.0 * mercators/pixel
        zoomRect.size.width = [self bounds].size.width * 2.0;
        zoomRect.size.height = [self bounds].size.height * 2.0;
        myOrigin.x = myOrigin.x - (zoomRect.size.width / 2.0);
        myOrigin.y = myOrigin.y - (zoomRect.size.height / 2.0);
        zoomRect.origin = myOrigin;
        
        [self setProjectedBounds:zoomRect animated:animated];
    }
    else
    {
        // Convert northEast/southWest into RMMercatorRect and call zoomWithBounds
        CLLocationCoordinate2D midpoint = {
            .latitude = (northEast.latitude + southWest.latitude) / 2,
            .longitude = (northEast.longitude + southWest.longitude) / 2
        };
        
        RMProjectedPoint myOrigin = [_projection coordinateToProjectedPoint:midpoint];
        RMProjectedPoint southWestPoint = [_projection coordinateToProjectedPoint:southWest];
        RMProjectedPoint northEastPoint = [_projection coordinateToProjectedPoint:northEast];
        RMProjectedPoint myPoint = {
            .x = northEastPoint.x - southWestPoint.x,
            .y = northEastPoint.y - southWestPoint.y
        };
        
		// Create the new zoom layout
        RMProjectedRect zoomRect;
        
        // Default is with scale = 2.0 * mercators/pixel
        zoomRect.size.width = self.bounds.size.width * 2.0;
        zoomRect.size.height = self.bounds.size.height * 2.0;
        
        if ((myPoint.x / self.bounds.size.width) < (myPoint.y / self.bounds.size.height))
        {
            if ((myPoint.y / self.bounds.size.height) > 1)
            {
                zoomRect.size.width = self.bounds.size.width * (myPoint.y / self.bounds.size.height);
                zoomRect.size.height = self.bounds.size.height * (myPoint.y / self.bounds.size.height);
            }
        }
        else
        {
            if ((myPoint.x / self.bounds.size.width) > 1)
            {
                zoomRect.size.width = self.bounds.size.width * (myPoint.x / self.bounds.size.width);
                zoomRect.size.height = self.bounds.size.height * (myPoint.x / self.bounds.size.width);
            }
        }
        
        myOrigin.x = myOrigin.x - (zoomRect.size.width / 2);
        myOrigin.y = myOrigin.y - (zoomRect.size.height / 2);
        zoomRect.origin = myOrigin;
        
        [self setProjectedBounds:zoomRect animated:animated];
    }
}

#pragma mark -
#pragma mark Cache

- (void)removeAllCachedImages
{
    [self.tileCache removeAllCachedImages];
}

#pragma mark -
#pragma mark MapView (ScrollView)

- (void)contentBoundsDidChange:(NSNotification *)notification
{
    NSClipView *clipView = [notification object];
    RMUIScrollView *scrollView = (RMUIScrollView *)[clipView superview];
    
    CGPoint contentOffset = [scrollView contentOffset];
//    RMLog(@"contentOffset: %f, %f", contentOffset.x, contentOffset.y);
    [self contentOffsetChanged:contentOffset];
}


- (void)createMapView
{
    self.layer = [CALayer layer];
    self.wantsLayer = YES;
    [self setAutoresizesSubviews:YES];
    [self setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
   
    [_tileSourcesContainer cancelAllDownloads];
    
    [_overlayView removeFromSuperview];
    _overlayView = nil;
    
    for (__strong RMMapTiledLayerView *tiledLayerView in _tiledLayersSuperview.subviews)
    {
        tiledLayerView.layer.contents = nil;
        [tiledLayerView removeFromSuperview];  tiledLayerView = nil;
    }
    
    [_tiledLayersSuperview removeFromSuperview];  _tiledLayersSuperview = nil;
    
    [_mapScrollView removeObserver:self forKeyPath:@"contentOffset"];
    [_mapScrollView removeFromSuperview];  _mapScrollView = nil;
    
    _mapScrollViewIsZooming = NO;
    
    int tileSideLength = [_tileSourcesContainer tileSideLength];
    CGSize contentSize = CGSizeMake(tileSideLength, tileSideLength); // zoom level 1
//    contentSize.width = 2048;
 //   contentSize.height  = 2048;
    
    _mapScrollView = [[RMMapScrollView alloc] initWithFrame:self.bounds];
    _mapScrollView.hasVerticalScroller = YES;
    _mapScrollView.hasHorizontalScroller = YES;
    
    [_mapScrollView setAutoresizesSubviews:YES];
    [_mapScrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
 

    //TODO: check
    /*
    _mapScrollView.delegate = self;
    _mapScrollView.opaque = NO;
    _mapScrollView.backgroundColor = [UIColor clearColor];
    _mapScrollView.showsVerticalScrollIndicator = NO;
    _mapScrollView.showsHorizontalScrollIndicator = NO;
    _mapScrollView.scrollsToTop = NO;
    _mapScrollView.scrollEnabled = _draggingEnabled;
    _mapScrollView.bounces = _bouncingEnabled;
    _mapScrollView.bouncesZoom = _bouncingEnabled;
     */
    
    _mapScrollView.contentSize = contentSize;
    _mapScrollView.minimumZoomScale = exp2f([self minZoom]);
    _mapScrollView.maximumZoomScale = exp2f([self maxZoom]);
    _mapScrollView.contentOffset = CGPointMake(0.0, 0.0);
//    _mapScrollView.clipsToBounds = NO;
    
    _tiledLayersSuperview = [[NSView alloc] initWithFrame:CGRectMake(0.0, 0.0, contentSize.width, contentSize.height)];
    [_tiledLayersSuperview setAutoresizesSubviews:YES];
    [_tiledLayersSuperview setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    _tiledLayersSuperview.layer = [CALayer layer];
    _tiledLayersSuperview.layer.masksToBounds = YES;
    _tiledLayersSuperview.wantsLayer = YES;

    //    _tiledLayersSuperview = [[NSView alloc] initWithFrame:CGRectMake(0.0, 0.0, 512, 512)];
//    _tiledLayersSuperview.userInteractionEnabled = NO;
    
    for (RMTileSource * tileSource in _tileSourcesContainer.tileSources)
    {
        RMMapTiledLayerView *tiledLayerView = [[RMMapTiledLayerView alloc] initWithFrame:CGRectMake(0.0, 0.0, contentSize.width, contentSize.height) mapView:self forTileSource:tileSource];
       
//        tiledLayerView.layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
//        sublayer.layoutManager = [CAConstraintLayoutManager layoutManager];

        ((CATiledLayer *)tiledLayerView.layer).tileSize = CGSizeMake(tileSideLength, tileSideLength);
        
        [_tiledLayersSuperview addSubview:tiledLayerView];
    }
    
    // dbainbridge UI/NSScrollView difference
    [_mapScrollView setDocumentView:_tiledLayersSuperview];
    //[_mapScrollView addSubview:_tiledLayersSuperview];
  
    _lastZoom = [self zoom];
    _lastContentOffset = _mapScrollView.contentOffset;
    _accumulatedDelta = CGPointMake(0.0, 0.0);
    _lastContentSize = _mapScrollView.contentSize;
    
    [[_mapScrollView contentView] setPostsBoundsChangedNotifications: YES];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(contentBoundsDidChange:)
                                                 name:NSViewBoundsDidChangeNotification
                                               object:_mapScrollView.contentView];
    
//    [_mapScrollView addObserver:self forKeyPath:@"contentOffset" options:(NSKeyValueObservingOptionNew|NSKeyValueObservingOptionOld) context:NULL];
    [self updateMetersPerPixel];
    
    _mapScrollView.mapScrollViewDelegate = self;
    
    _mapScrollView.zoomScale = exp2f([self zoom]);
    [self setDecelerationMode:_decelerationMode];
    
    if (_backgroundView) {
        [_backgroundView setAutoresizesSubviews:YES];
        [_backgroundView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        [self insertSubview:_mapScrollView aboveSubview:_backgroundView];
    }
    else
        [self insertSubview:_mapScrollView atIndex:0];
    
    _overlayView = [[RMMapOverlayView alloc] initWithFrame:[self bounds]];
    [_overlayView setAutoresizesSubviews:YES];
    [_overlayView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
   
//    _overlayView.userInteractionEnabled = NO;
    
    //[_tiledLayersSuperview.layer addSublayer:_overlayView.layer];
    [self insertSubview:_overlayView aboveSubview:_mapScrollView];
       
    // add gesture recognizers
#if 0
    // one finger taps
    UITapGestureRecognizer *doubleTapRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap:)];
    doubleTapRecognizer.numberOfTouchesRequired = 1;
    doubleTapRecognizer.numberOfTapsRequired = 2;
    doubleTapRecognizer.delegate = self;
    
    UITapGestureRecognizer *singleTapRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleSingleTap:)];
    singleTapRecognizer.numberOfTouchesRequired = 1;
    [singleTapRecognizer requireGestureRecognizerToFail:doubleTapRecognizer];
    singleTapRecognizer.delegate = self;
    
    UILongPressGestureRecognizer *longPressRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    longPressRecognizer.delegate = self;
    
    [self addGestureRecognizer:singleTapRecognizer];
    [self addGestureRecognizer:doubleTapRecognizer];
    [self addGestureRecognizer:longPressRecognizer];
    
    // two finger taps
    UITapGestureRecognizer *twoFingerSingleTapRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTwoFingerSingleTap:)];
    twoFingerSingleTapRecognizer.numberOfTouchesRequired = 2;
    twoFingerSingleTapRecognizer.delegate = self;
    
    [self addGestureRecognizer:twoFingerSingleTapRecognizer];
    
    // pan
    UIPanGestureRecognizer *panGestureRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanGesture:)];
    panGestureRecognizer.minimumNumberOfTouches = 1;
    panGestureRecognizer.maximumNumberOfTouches = 1;
    
    // the delegate is used to decide whether a pan should be handled by this
    // recognizer or by the pan gesture recognizer of the scrollview
    panGestureRecognizer.delegate = self;
    
    // the pan recognizer is added to the scrollview as it competes with the
    // pan recognizer of the scrollview
    [_mapScrollView addGestureRecognizer:panGestureRecognizer];
#endif
    [self setZoom:1];
    [_mapScrollView zoomToScale:[self zoom]];
    [_visibleAnnotations removeAllObjects];
    [self correctPositionOfAllAnnotations];
}

- (NSView *)viewForZoomingInScrollView:(NSScrollView *)scrollView
{
    return _tiledLayersSuperview;
}

// TODO: check
#if 0
- (void)scrollViewWillBeginDragging:(NSScrollView *)scrollView
{
    [self registerMoveEventByUser:YES];
    
    if (self.userTrackingMode != RMUserTrackingModeNone)
        self.userTrackingMode = RMUserTrackingModeNone;
}

- (void)scrollViewDidEndDragging:(NSScrollView *)scrollView willDecelerate:(BOOL)decelerate
{
    if ( ! decelerate)
        [self completeMoveEventAfterDelay:0];
}

- (void)scrollViewWillBeginDecelerating:(NSScrollView *)scrollView
{
    if (_decelerationMode == RMMapDecelerationOff)
        [scrollView setContentOffset:scrollView.contentOffset animated:NO];
}

- (void)scrollViewDidEndDecelerating:(NSScrollView *)scrollView
{
    [self completeMoveEventAfterDelay:0];
}

- (void)scrollViewDidEndScrollingAnimation:(NSScrollView *)scrollView
{
    [self completeMoveEventAfterDelay:0];
}

- (void)scrollViewWillBeginZooming:(NSScrollView *)scrollView withView:(NSView *)view
{
    [self registerZoomEventByUser:(scrollView.pinchGestureRecognizer.state == UIGestureRecognizerStateBegan)];
    
    _mapScrollViewIsZooming = YES;
    
    if (_loadingTileView)
        _loadingTileView.mapZooming = YES;
}

- (void)scrollViewDidEndZooming:(NSScrollView *)scrollView withView:(NSView *)view atScale:(float)scale
{
    [self completeMoveEventAfterDelay:0];
    [self completeZoomEventAfterDelay:0];
    
    _mapScrollViewIsZooming = NO;
    
    // slight jiggle fixes problems with UIScrollView
    // briefly allowing zoom beyond min
    //
    [self moveBy:CGSizeMake(-1, -1)];
    [self moveBy:CGSizeMake( 1,  1)];
    
    [self correctPositionOfAllAnnotations];
    
    if (_loadingTileView)
        _loadingTileView.mapZooming = NO;
}

- (void)scrollViewDidScroll:(NSScrollView *)scrollView
{
    if (_loadingTileView)
    {
        CGSize delta = CGSizeMake(scrollView.contentOffset.x - _lastContentOffset.x, scrollView.contentOffset.y - _lastContentOffset.y);
        CGPoint newOffset = CGPointMake(_loadingTileView.contentOffset.x + delta.width, _loadingTileView.contentOffset.y + delta.height);
        _loadingTileView.contentOffset = newOffset;
    }
}

- (void)scrollViewDidZoom:(NSScrollView *)scrollView
{
    BOOL wasUserAction = (scrollView.pinchGestureRecognizer.state == UIGestureRecognizerStateChanged);
    
    [self registerZoomEventByUser:wasUserAction];
    
    if (self.userTrackingMode != RMUserTrackingModeNone && wasUserAction)
        self.userTrackingMode = RMUserTrackingModeNone;
    
    [self correctPositionOfAllAnnotations];
    
    if (_zoom < 3 && self.userTrackingMode == RMUserTrackingModeFollowWithHeading)
        self.userTrackingMode = RMUserTrackingModeFollow;
}
#endif

// Detect dragging/zooming

- (void)scrollView:(RMMapScrollView *)aScrollView correctedContentOffset:(inout CGPoint *)aContentOffset
{
    if ( ! _constrainMovement)
        return;
    
    if (CGPointEqualToPoint(_lastContentOffset, *aContentOffset))
        return;
    
    // The first offset during zooming out (animated) is always garbage
    if (_mapScrollViewIsZooming == YES &&
        _mapScrollView.zooming == NO &&
        _lastContentSize.width > _mapScrollView.contentSize.width &&
        ((*aContentOffset).y - _lastContentOffset.y) == 0.0)
    {
        return;
    }
    
    RMProjectedRect planetBounds = _projection.planetBounds;
    double currentMetersPerPixel = planetBounds.size.width / aScrollView.contentSize.width;
    
    CGPoint bottomLeft = CGPointMake((*aContentOffset).x,
                                     aScrollView.contentSize.height - ((*aContentOffset).y + aScrollView.bounds.size.height));
    
    RMProjectedRect normalizedProjectedRect;
    normalizedProjectedRect.origin.x = (bottomLeft.x * currentMetersPerPixel) - fabs(planetBounds.origin.x);
    normalizedProjectedRect.origin.y = (bottomLeft.y * currentMetersPerPixel) - fabs(planetBounds.origin.y);
    normalizedProjectedRect.size.width = aScrollView.bounds.size.width * currentMetersPerPixel;
    normalizedProjectedRect.size.height = aScrollView.bounds.size.height * currentMetersPerPixel;
    
    if (RMProjectedRectContainsProjectedRect(_constrainingProjectedBounds, normalizedProjectedRect))
        return;
    
    RMProjectedRect fittedProjectedRect = [self fitProjectedRect:normalizedProjectedRect intoRect:_constrainingProjectedBounds];
    
    RMProjectedPoint normalizedProjectedPoint;
	normalizedProjectedPoint.x = fittedProjectedRect.origin.x + fabs(planetBounds.origin.x);
	normalizedProjectedPoint.y = fittedProjectedRect.origin.y + fabs(planetBounds.origin.y);
    
    CGPoint correctedContentOffset = CGPointMake(normalizedProjectedPoint.x / currentMetersPerPixel,
                                                 aScrollView.contentSize.height - ((normalizedProjectedPoint.y / currentMetersPerPixel) + aScrollView.bounds.size.height));
    *aContentOffset = correctedContentOffset;
}

- (void)scrollView:(RMMapScrollView *)aScrollView correctedContentSize:(inout CGSize *)aContentSize
{
    if ( ! _constrainMovement)
        return;
    
    RMProjectedRect planetBounds = _projection.planetBounds;
    double currentMetersPerPixel = planetBounds.size.width / (*aContentSize).width;
    
    RMProjectedSize projectedSize;
    projectedSize.width = aScrollView.bounds.size.width * currentMetersPerPixel;
    projectedSize.height = aScrollView.bounds.size.height * currentMetersPerPixel;
    
    if (RMProjectedSizeContainsProjectedSize(_constrainingProjectedBounds.size, projectedSize))
        return;
    
    CGFloat factor = 1.0;
    if (projectedSize.width > _constrainingProjectedBounds.size.width)
        factor = (projectedSize.width / _constrainingProjectedBounds.size.width);
    else
        factor = (projectedSize.height / _constrainingProjectedBounds.size.height);
    
    *aContentSize = CGSizeMake((*aContentSize).width * factor, (*aContentSize).height * factor);
}

- (NSUInteger)mapSize:(int)levelOfDetail
{
    return (NSUInteger) 256 << levelOfDetail;
}

- (void)updateMetersPerPixel
{
    RMProjectedRect planetBounds = _projection.planetBounds;
    _metersPerPixel = (2 * M_PI * 6378137) / (256 * pow(2, _zoom - 1));
//    _metersPerPixel = planetBounds.size.width / _mapScrollView.contentSize.width;
}

//- (void)observeValueForKeyPath:(NSString *)aKeyPath ofObject:(id)anObject change:(NSDictionary *)change context:(void *)context
- (void)contentOffsetChanged:(CGPoint)newContentOffset
{
 /*   NSValue *oldValue = [change objectForKey:NSKeyValueChangeOldKey],
    *newValue = [change objectForKey:NSKeyValueChangeNewKey];
    
    CGPoint oldContentOffset = [oldValue CGPointValue],
    newContentOffset = [newValue CGPointValue];
  */  
    if (CGPointEqualToPoint(_lastContentOffset, newContentOffset))
        return;
    
    // The first offset during zooming out (animated) is always garbage
    if (_mapScrollViewIsZooming == YES &&
        _mapScrollView.zooming == NO &&
        _lastContentSize.width > _mapScrollView.contentSize.width &&
        (newContentOffset.y - _lastContentOffset.y) == 0.0)
    {
        _lastContentOffset = _mapScrollView.contentOffset;
        _lastContentSize = _mapScrollView.contentSize;
        
        return;
    }
    
    //    RMLog(@"contentOffset: {%.0f,%.0f} -> {%.1f,%.1f} (%.0f,%.0f)", oldContentOffset.x, oldContentOffset.y, newContentOffset.x, newContentOffset.y, newContentOffset.x - oldContentOffset.x, newContentOffset.y - oldContentOffset.y);
    //    RMLog(@"contentSize: {%.0f,%.0f} -> {%.0f,%.0f}", _lastContentSize.width, _lastContentSize.height, mapScrollView.contentSize.width, mapScrollView.contentSize.height);
    //    RMLog(@"isZooming: %d, scrollview.zooming: %d", _mapScrollViewIsZooming, mapScrollView.zooming);
    
    [self updateMetersPerPixel];
    
    _zoom = log2f(_mapScrollView.zoomScale);
    _zoom = (_zoom > _maxZoom) ? _maxZoom : _zoom;
    _zoom = (_zoom < _minZoom) ? _minZoom : _zoom;
    
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(correctPositionOfAllAnnotations) object:nil];
    
    if (_zoom == _lastZoom)
    {
        CGPoint contentOffset = _mapScrollView.contentOffset;
        CGPoint delta = CGPointMake(_lastContentOffset.x - contentOffset.x, _lastContentOffset.y - contentOffset.y);
        _accumulatedDelta.x += delta.x;
        _accumulatedDelta.y += delta.y;
        
        if (fabsf(_accumulatedDelta.x) < kZoomRectPixelBuffer && fabsf(_accumulatedDelta.y) < kZoomRectPixelBuffer)
        {
            [_overlayView moveLayersBy:_accumulatedDelta];
            [self performSelector:@selector(correctPositionOfAllAnnotations) withObject:nil afterDelay:0.1];
        }
        else
        {
            if (_mapScrollViewIsZooming)
                [self correctPositionOfAllAnnotationsIncludingInvisibles:NO animated:YES];
            else
                [self correctPositionOfAllAnnotations];
        }
    }
    else
    {
        [self correctPositionOfAllAnnotationsIncludingInvisibles:NO animated:(_mapScrollViewIsZooming && !_mapScrollView.zooming)];
        
#warning fixme
        /*
        if (_currentAnnotation && ! [_currentAnnotation isKindOfClass:[RMMarker class]])
        {
            // adjust shape annotation callouts for frame changes during zoom
            //
            _currentCallout.delegate = nil;
            
            [_currentCallout presentCalloutFromRect:_currentAnnotation.layer.bounds
                                            inLayer:_currentAnnotation.layer
                                 constrainedToLayer:self.layer
                           permittedArrowDirections:SMCalloutArrowDirectionDown
                                           animated:NO];
            
            _currentCallout.delegate = self;
        }
        */
        _lastZoom = _zoom;
    }
    
    _lastContentOffset = _mapScrollView.contentOffset;
    _lastContentSize = _mapScrollView.contentSize;
    
    if (delegateRespondsTo.mapViewRegionDidChange)
        [_delegate mapViewRegionDidChange:self];
}

// dbainbridge
- (void)centerMapAtPixelPoint:(CGPoint)targetPoint
{
    NSRect visibleRect = _mapScrollView.documentVisibleRect;
    NSClipView *contentView = [_mapScrollView contentView];
    
    CGPoint newPoint;
//    newPoint.x = (targetPoint.x + visibleRect.origin.x - NSWidth(visibleRect)/2.0);
//    newPoint.y = (targetPoint.y + visibleRect.origin.y - NSHeight(visibleRect)/2.0);
    newPoint.x = (targetPoint.x + contentView.bounds.origin.x - NSWidth(contentView.frame)/2.0);
    newPoint.y = (targetPoint.y + contentView.bounds.origin.y - NSHeight(contentView.frame)/2.0);

    [_mapScrollView.documentView scrollPoint:newPoint];
}

#pragma mark - Gesture Recognizers and event handling
- (void)mouseDown:(NSEvent *)theEvent {
    if ([theEvent clickCount] > 1) {
        NSPoint curPoint = [self convertPoint:[theEvent locationInWindow] fromView:nil];
        [self doubleTapAtPoint:curPoint];
        
    } 
    else {
        self.clickPoint = [theEvent locationInWindow];
        self.originalOrigin = [[_mapScrollView contentView] bounds].origin;
        
    }
}

- (void) mouseDragged: (NSEvent*)theEvent {
    NSPoint newPoint = [theEvent locationInWindow];
    NSPoint newOrigin = NSMakePoint(self.originalOrigin.x + (self.clickPoint.x - newPoint.x),
                                    self.originalOrigin.y + (self.clickPoint.y - newPoint.y));
    
    NSClipView *clipView = [_mapScrollView contentView];
    
    [clipView scrollToPoint:[clipView constrainScrollPoint:newOrigin]];
//    [_mapScrollView reflectScrolledClipView:clipView];
}

- (void)magnifyWithEvent:(NSEvent *)theEvent
{
    float magnification = exp2f([theEvent magnification]);
    
    [self zoomByFactor:magnification near:CGPointZero animated:NO];
}

- (void)doubleTapAtPoint:(CGPoint)aPoint
{
//    [self centerMapAtPixelPoint:aPoint];
 //   return;
    
    if (self.zoom < self.maxZoom)
    {
        [self registerZoomEventByUser:YES];

        if (self.zoomingInPivotsAroundCenter)
        {
            [self zoomInToNextNativeZoomAt:[self convertPoint:aPoint fromView:self.superview] animated:YES];
   //         [self zoomInToNextNativeZoomAt:[self convertPoint:self.center fromView:self.superview] animated:YES];
        }
        else if (self.userTrackingMode != RMUserTrackingModeNone && fabsf(aPoint.x - [self coordinateToPixel:self.userLocation.location.coordinate].x) < 75 && fabsf(aPoint.y - [self coordinateToPixel:self.userLocation.location.coordinate].y) < 75)
        {
            [self zoomInToNextNativeZoomAt:[self coordinateToPixel:self.userLocation.location.coordinate] animated:YES];
        }
        else
        {
            [self registerMoveEventByUser:YES];
            
            [self zoomInToNextNativeZoomAt:aPoint animated:YES];
        }
    }
    
    if (delegateRespondsTo.doubleTapOnMap)
        [_delegate doubleTapOnMap:self at:aPoint];
}



- (RMAnnotation *)findAnnotationInLayer:(CALayer *)layer
{
    if ([layer respondsToSelector:@selector(annotation)])
        return [((RMMarker *)layer) annotation];
    
    CALayer *superlayer = [layer superlayer];
    
    if (superlayer != nil && [superlayer respondsToSelector:@selector(annotation)])
        return [((RMMarker *)superlayer) annotation];
    else if ([superlayer superlayer] != nil && [[superlayer superlayer] respondsToSelector:@selector(annotation)])
        return [((RMMarker *)[superlayer superlayer]) annotation];
    
    return nil;
}

- (void)singleTapAtPoint:(CGPoint)aPoint
{
    if (delegateRespondsTo.singleTapOnMap)
        [_delegate singleTapOnMap:self at:aPoint];
}

- (void)handleSingleTap:(NSEvent *)event
{
    NSPoint hitPoint = [self convertPoint:[event locationInWindow] fromView:nil];
    CALayer *hit = [_overlayView overlayHitTest:hitPoint];
    
    if (_currentAnnotation && ! [hit isEqual:_currentAnnotation.layer])
    {
        [self deselectAnnotation:_currentAnnotation animated:( ! [hit isKindOfClass:[RMMarker class]])];
    }
    
    if ( ! hit)
    {
        [self singleTapAtPoint:hitPoint];
        return;
    }
    
    CALayer *superlayer = [hit superlayer];
    
    // See if tap was on an annotation layer or marker label and send delegate protocol method
    if ([hit isKindOfClass:[RMMapLayer class]])
    {
        [self tapOnAnnotation:[((RMMapLayer *)hit) annotation] atPoint:hitPoint];
    }
    else if (superlayer != nil && [superlayer isKindOfClass:[RMMarker class]])
    {
        [self tapOnLabelForAnnotation:[((RMMarker *)superlayer) annotation] atPoint:hitPoint];
    }
    else if ([superlayer superlayer] != nil && [[superlayer superlayer] isKindOfClass:[RMMarker class]])
    {
        [self tapOnLabelForAnnotation:[((RMMarker *)[superlayer superlayer]) annotation] atPoint:hitPoint];
    }
    else
    {
        [self singleTapAtPoint:hitPoint];
    }
}

// Overlay

- (void)tapOnAnnotation:(RMAnnotation *)anAnnotation atPoint:(CGPoint)aPoint
{
    if (anAnnotation.isEnabled && ! [anAnnotation isEqual:_currentAnnotation])
        [self selectAnnotation:anAnnotation animated:YES];
    
    if (delegateRespondsTo.tapOnAnnotation && anAnnotation)
    {
        [_delegate tapOnAnnotation:anAnnotation onMap:self];
    }
    else
    {
        if (delegateRespondsTo.singleTapOnMap)
            [_delegate singleTapOnMap:self at:aPoint];
    }
}

- (void)tapOnLabelForAnnotation:(RMAnnotation *)anAnnotation atPoint:(CGPoint)aPoint
{
    if (delegateRespondsTo.tapOnLabelForAnnotation && anAnnotation)
    {
        [_delegate tapOnLabelForAnnotation:anAnnotation onMap:self];
    }
    else if (delegateRespondsTo.tapOnAnnotation && anAnnotation)
    {
        [_delegate tapOnAnnotation:anAnnotation onMap:self];
    }
    else
    {
        if (delegateRespondsTo.singleTapOnMap)
            [_delegate singleTapOnMap:self at:aPoint];
    }
}
/*
- (void)selectAnnotation:(RMAnnotation *)anAnnotation animated:(BOOL)animated
{
    if ( ! anAnnotation && _currentAnnotation)
    {
        [self deselectAnnotation:_currentAnnotation animated:animated];
    }
    else if (anAnnotation.isEnabled && ! [anAnnotation isEqual:_currentAnnotation])
    {
        [self deselectAnnotation:_currentAnnotation animated:NO];
        
        _currentAnnotation = anAnnotation;
        
        
        if (anAnnotation.layer.canShowCallout && anAnnotation.title)
        {
            _currentCallout = [SMCalloutView new];
            
            _currentCallout.backgroundView = [SMCalloutBackgroundView systemBackgroundView];
            
            _currentCallout.title    = anAnnotation.title;
            _currentCallout.subtitle = anAnnotation.subtitle;
            
            _currentCallout.calloutOffset = anAnnotation.layer.calloutOffset;
            
            if (anAnnotation.layer.leftCalloutAccessoryView)
            {
                if ([anAnnotation.layer.leftCalloutAccessoryView isKindOfClass:[UIControl class]])
                    [anAnnotation.layer.leftCalloutAccessoryView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapOnCalloutAccessoryWithGestureRecognizer:)]];
                
                _currentCallout.leftAccessoryView = anAnnotation.layer.leftCalloutAccessoryView;
            }
            
            if (anAnnotation.layer.rightCalloutAccessoryView)
            {
                if ([anAnnotation.layer.rightCalloutAccessoryView isKindOfClass:[UIControl class]])
                    [anAnnotation.layer.rightCalloutAccessoryView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapOnCalloutAccessoryWithGestureRecognizer:)]];
                
                _currentCallout.rightAccessoryView = anAnnotation.layer.rightCalloutAccessoryView;
            }
            
            _currentCallout.delegate = self;
            
            [_currentCallout presentCalloutFromRect:anAnnotation.layer.bounds
                                            inLayer:anAnnotation.layer
                                 constrainedToLayer:self.layer
                           permittedArrowDirections:SMCalloutArrowDirectionDown
                                           animated:animated];
        }
        
        [self correctPositionOfAllAnnotations];
        
        anAnnotation.layer.zPosition = _currentCallout.layer.zPosition = MAXFLOAT;
        
        if (delegateRespondsTo.didSelectAnnotation)
            [_delegate mapView:self didSelectAnnotation:anAnnotation];
    }
}

- (void)deselectAnnotation:(RMAnnotation *)annotation animated:(BOOL)animated
{
    if ([annotation isEqual:_currentAnnotation])
    {
        [_currentCallout dismissCalloutAnimated:animated];
        
        if (animated)
            [self performSelector:@selector(correctPositionOfAllAnnotations) withObject:nil afterDelay:1.0/3.0];
        else
            [self correctPositionOfAllAnnotations];
        
        _currentAnnotation = nil;
        _currentCallout = nil;
        
        if (_delegateHasDidDeselectAnnotation)
            [_delegate mapView:self didDeselectAnnotation:annotation];
    }
}

*/
- (void)setSelectedAnnotation:(RMAnnotation *)selectedAnnotation
{
    if ( ! [selectedAnnotation isEqual:_currentAnnotation])
        [self selectAnnotation:selectedAnnotation animated:YES];
}

- (RMAnnotation *)selectedAnnotation
{
    return _currentAnnotation;
}

#if 0
- (void)handleDoubleTap:(UIGestureRecognizer *)recognizer
{
    CALayer *hit = [_overlayView overlayHitTest:[recognizer locationInView:self]];
    
    if ( ! hit)
    {
        [self doubleTapAtPoint:[recognizer locationInView:self]];
        return;
    }
    
    CALayer *superlayer = [hit superlayer];
    
    // See if tap was on a marker or marker label and send delegate protocol method
    if ([hit isKindOfClass:[RMMarker class]])
    {
        [self doubleTapOnAnnotation:[((RMMarker *)hit) annotation] atPoint:[recognizer locationInView:self]];
    }
    else if (superlayer != nil && [superlayer isKindOfClass:[RMMarker class]])
    {
        [self doubleTapOnLabelForAnnotation:[((RMMarker *)superlayer) annotation] atPoint:[recognizer locationInView:self]];
    }
    else if ([superlayer superlayer] != nil && [[superlayer superlayer] isKindOfClass:[RMMarker class]])
    {
        [self doubleTapOnLabelForAnnotation:[((RMMarker *)[superlayer superlayer]) annotation] atPoint:[recognizer locationInView:self]];
    }
    else
    {
        [self doubleTapAtPoint:[recognizer locationInView:self]];
    }
}

- (void)handleTwoFingerSingleTap:(UIGestureRecognizer *)recognizer
{
    if (self.zoom > self.minZoom)
    {
        [self registerZoomEventByUser:YES];
        
        CGPoint centerPoint = [self convertPoint:self.center fromView:self.superview];
        
        if (self.userTrackingMode != RMUserTrackingModeNone)
            centerPoint = [self coordinateToPixel:self.userLocation.location.coordinate];
        
        [self zoomOutToNextNativeZoomAt:centerPoint animated:YES];
    }
    
    if (delegateRespondsTo.singleTapTwoFingersOnMap)
        [_delegate singleTapTwoFingersOnMap:self at:[recognizer locationInView:self]];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)recognizer
{
    if (recognizer.state != UIGestureRecognizerStateBegan)
        return;
    
    if ( ! delegateRespondsTo.longPressOnMap && ! delegateRespondsTo.delegateHasLongPressOnAnnotation)
        return;
    
    CALayer *hit = [_overlayView overlayHitTest:[recognizer locationInView:self]];
    
    if (_currentAnnotation && [hit isEqual:_currentAnnotation.layer])
        [self deselectAnnotation:_currentAnnotation animated:NO];
    
    if ([hit isKindOfClass:[RMMapLayer class]] && delegateRespondsTo.longPressOnAnnotation)
        [_delegate longPressOnAnnotation:[((RMMapLayer *)hit) annotation] onMap:self];
    
    else if (delegateRespondsTo.longPressOnMap)
        [_delegate longPressOnMap:self at:[recognizer locationInView:self]];
}

// defines when the additional pan gesture recognizer on the scroll should handle the gesture
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer
{
    if ([recognizer isKindOfClass:[UIPanGestureRecognizer class]])
    {
        // check whether our custom pan gesture recognizer should start recognizing the gesture
        CALayer *hit = [_overlayView overlayHitTest:[recognizer locationInView:_overlayView]];
        
        if ([hit isEqual:_overlayView.layer])
            return NO;
        
        if (!hit || ([hit respondsToSelector:@selector(draggingEnabled)] && ![(RMMarker *)hit draggingEnabled]))
            return NO;
        
        if ( ! [self shouldDragAnnotation:[self findAnnotationInLayer:hit]])
            return NO;
    }
    
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch
{
    if ([touch.view isKindOfClass:[UIControl class]])
        return NO;
    
    return YES;
}

- (void)handlePanGesture:(UIPanGestureRecognizer *)recognizer
{
    if (recognizer.state == UIGestureRecognizerStateBegan)
    {
        CALayer *hit = [_overlayView.layer hitTest:[recognizer locationInView:self]];
        
        if ( ! hit)
            return;
        
        if ([hit respondsToSelector:@selector(draggingEnabled)] && ![(RMMarker *)hit draggingEnabled])
            return;
        
        _lastDraggingTranslation = CGPointZero;
        _draggedAnnotation = [self findAnnotationInLayer:hit];
    }
    
    if (recognizer.state == UIGestureRecognizerStateChanged)
    {
        CGPoint translation = [recognizer translationInView:_overlayView];
        CGPoint delta = CGPointMake(_lastDraggingTranslation.x - translation.x, _lastDraggingTranslation.y - translation.y);
        _lastDraggingTranslation = translation;
        
        [CATransaction begin];
        [CATransaction setAnimationDuration:0];
        [self didDragAnnotation:_draggedAnnotation withDelta:delta];
        [CATransaction commit];
    }
    else if (recognizer.state == UIGestureRecognizerStateEnded)
    {
        [self didEndDragAnnotation:_draggedAnnotation];
        _draggedAnnotation = nil;
    }
}


- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    if (_currentCallout)
    {
        UIView *calloutCandidate = [_currentCallout hitTest:[_currentCallout convertPoint:point fromView:self] withEvent:event];
        
        if (calloutCandidate)
            return calloutCandidate;
    }
    
    return [super hitTest:point withEvent:event];
}


- (void)popupCalloutViewForAnnotation:(RMAnnotation *)anAnnotation
{
    [self popupCalloutViewForAnnotation:anAnnotation animated:YES];
}

- (void)popupCalloutViewForAnnotation:(RMAnnotation *)anAnnotation animated:(BOOL)animated
{
    _currentAnnotation = anAnnotation;
    
    _currentCallout = [SMCalloutView new];
    
    _currentCallout.title    = anAnnotation.title;
    _currentCallout.subtitle = anAnnotation.subtitle;
    
    _currentCallout.calloutOffset = anAnnotation.layer.calloutOffset;
    
    if (anAnnotation.layer.leftCalloutAccessoryView)
    {
        if ([anAnnotation.layer.leftCalloutAccessoryView isKindOfClass:[UIControl class]])
            [anAnnotation.layer.leftCalloutAccessoryView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapOnCalloutAccessoryWithGestureRecognizer:)]];
        
        _currentCallout.leftAccessoryView = anAnnotation.layer.leftCalloutAccessoryView;
    }
    
    if (anAnnotation.layer.rightCalloutAccessoryView)
    {
        if ([anAnnotation.layer.rightCalloutAccessoryView isKindOfClass:[UIControl class]])
            [anAnnotation.layer.rightCalloutAccessoryView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapOnCalloutAccessoryWithGestureRecognizer:)]];
        
        _currentCallout.rightAccessoryView = anAnnotation.layer.rightCalloutAccessoryView;
    }
    
    _currentCallout.delegate = self;
    
    [self correctPositionOfAllAnnotations];
    
    anAnnotation.layer.zPosition = _currentCallout.layer.zPosition = MAXFLOAT;
    
    [_currentCallout presentCalloutFromRect:anAnnotation.layer.bounds
                                    inLayer:anAnnotation.layer
                         constrainedToLayer:self.layer
                   permittedArrowDirections:SMCalloutArrowDirectionDown
                                   animated:animated];
}

- (NSTimeInterval)calloutView:(SMCalloutView *)calloutView delayForRepositionWithSize:(CGSize)offset
{
    [self registerMoveEventByUser:NO];
    
    CGPoint contentOffset = _mapScrollView.contentOffset;
    
    contentOffset.x -= offset.width;
    contentOffset.y -= offset.height;
    
    [_mapScrollView setContentOffset:contentOffset animated:YES];
    
    [self completeMoveEventAfterDelay:kSMCalloutViewRepositionDelayForUIScrollView];
    
    return kSMCalloutViewRepositionDelayForUIScrollView;
}

- (void)tapOnCalloutAccessoryWithGestureRecognizer:(UIGestureRecognizer *)recognizer
{
    if (delegateRespondsTo.tapOnCalloutAccessoryControlForAnnotation)
        [_delegate tapOnCalloutAccessoryControl:(UIControl *)recognizer.view forAnnotation:_currentAnnotation onMap:self];
}

- (void)doubleTapOnAnnotation:(RMAnnotation *)anAnnotation atPoint:(CGPoint)aPoint
{
    if (delegateRespondsTo.doubleTapOnAnnotation && anAnnotation)
    {
        [_delegate doubleTapOnAnnotation:anAnnotation onMap:self];
    }
    else
    {
        [self doubleTapAtPoint:aPoint];
    }
}


- (void)doubleTapOnLabelForAnnotation:(RMAnnotation *)anAnnotation atPoint:(CGPoint)aPoint
{
    if (delegateRespondsTo.doubleTapOnLabelForAnnotation && anAnnotation)
    {
        [_delegate doubleTapOnLabelForAnnotation:anAnnotation onMap:self];
    }
    else if (delegateRespondsTo.doubleTapOnAnnotation && anAnnotation)
    {
        [_delegate doubleTapOnAnnotation:anAnnotation onMap:self];
    }
    else
    {
        [self doubleTapAtPoint:aPoint];
    }
}

- (BOOL)shouldDragAnnotation:(RMAnnotation *)anAnnotation
{
    if (delegateRespondsTo.shouldDragMarker)
        return [_delegate mapView:self shouldDragAnnotation:anAnnotation];
    else
        return NO;
}

- (void)didDragAnnotation:(RMAnnotation *)anAnnotation withDelta:(CGPoint)delta
{
    if (delegateRespondsTo.didDragMarker)
        [_delegate mapView:self didDragAnnotation:anAnnotation withDelta:delta];
}

- (void)didEndDragAnnotation:(RMAnnotation *)anAnnotation
{
    if (delegateRespondsTo.didEndDragMarker)
        [_delegate mapView:self didEndDragAnnotation:anAnnotation];
}
#endif

#pragma mark -
#pragma mark Snapshots

//TODO: fix me
#if 0
- (NSImage *)takeSnapshotAndIncludeOverlay:(BOOL)includeOverlay
{
    _overlayView.hidden = !includeOverlay;
    
    UIGraphicsBeginImageContextWithOptions(self.bounds.size, self.opaque, [[UIScreen mainScreen] scale]);
    
    for (RMMapTiledLayerView *tiledLayerView in _tiledLayersSuperview.subviews)
        tiledLayerView.useSnapshotRenderer = YES;
    
    [self.layer renderInContext:UIGraphicsGetCurrentContext()];
    
    for (RMMapTiledLayerView *tiledLayerView in _tiledLayersSuperview.subviews)
        tiledLayerView.useSnapshotRenderer = NO;
    
    NSImage *image = UIGraphicsGetImageFromCurrentImageContext();
    
    UIGraphicsEndImageContext();
    
    _overlayView.hidden = NO;
    
    return image;
}

- (NSImage *)takeSnapshot
{
    return [self takeSnapshotAndIncludeOverlay:YES];
}
#endif

#pragma mark - TileSources

- (RMTileSourcesContainer *)tileSourcesContainer
{
    return _tileSourcesContainer;
}

- (RMTileSource *)tileSource
{
    NSArray *tileSources = [_tileSourcesContainer tileSources];
    
    if ([tileSources count] > 0)
        return [tileSources objectAtIndex:0];
    
    return nil;
}

- (NSArray *)tileSources
{
    return [_tileSourcesContainer tileSources];
}

- (void)setTileSource:(RMTileSource *)tileSource
{
    [_tileSourcesContainer removeAllTileSources];
    [self addTileSource:tileSource];
}

- (void)setTileSources:(NSArray *)tileSources
{
    if ( ! [_tileSourcesContainer setTileSources:tileSources])
        return;
    
    RMProjectedPoint centerPoint = [self centerProjectedPoint];
    
    _projection = [_tileSourcesContainer projection];
    
    _mercatorToTileProjection = [_tileSourcesContainer mercatorToTileProjection];
    
    [self setTileSourcesConstraintsFromLatitudeLongitudeBoundingBox:[_tileSourcesContainer latitudeLongitudeBoundingBox]];
    [self setTileSourcesMinZoom:_tileSourcesContainer.minZoom];
    [self setTileSourcesMaxZoom:_tileSourcesContainer.maxZoom];
    [self setZoom:[self zoom]]; // setZoom clamps zoom level to min/max limits
    
    // Recreate the map layer
    [self createMapView];
    
    [self setCenterProjectedPoint:centerPoint animated:NO];
}

- (void)addTileSource:(RMTileSource *)tileSource
{
    [self addTileSource:tileSource atIndex:-1];
}

- (void)addTileSource:(RMTileSource *)newTileSource atIndex:(NSUInteger)index
{
    if ([_tileSourcesContainer.tileSources containsObject:newTileSource])
        return;
    
    if ( ! [_tileSourcesContainer addTileSource:newTileSource atIndex:index])
        return;
    
    RMProjectedPoint centerPoint = [self centerProjectedPoint];
    
    _projection = [_tileSourcesContainer projection];
    
    _mercatorToTileProjection = [_tileSourcesContainer mercatorToTileProjection];
    
    [self setTileSourcesConstraintsFromLatitudeLongitudeBoundingBox:[_tileSourcesContainer latitudeLongitudeBoundingBox]];

    [self setTileSourcesMinZoom:_tileSourcesContainer.minZoom];
    [self setTileSourcesMaxZoom:_tileSourcesContainer.maxZoom];
    [self setZoom:[self zoom]]; // setZoom clamps zoom level to min/max limits
    
    // Recreate the map layer
    NSUInteger tileSourcesContainerSize = [[_tileSourcesContainer tileSources] count];
    
    if (tileSourcesContainerSize == 1)
    {
        [self createMapView];
    }
    else
    {
        NSUInteger tileSideLength = [_tileSourcesContainer tileSideLength];
        CGSize contentSize = CGSizeMake(tileSideLength, tileSideLength); // zoom level 1
        
        RMMapTiledLayerView *tiledLayerView = [[RMMapTiledLayerView alloc] initWithFrame:CGRectMake(0.0, 0.0, contentSize.width, contentSize.height) mapView:self forTileSource:newTileSource];
        
        ((CATiledLayer *)tiledLayerView.layer).tileSize = CGSizeMake(tileSideLength, tileSideLength);
        
        if (index >= [[_tileSourcesContainer tileSources] count])
            [_tiledLayersSuperview addSubview:tiledLayerView];
        else
            [_tiledLayersSuperview insertSubview:tiledLayerView atIndex:index];
    }
    
    [self setCenterProjectedPoint:centerPoint animated:NO];
}

- (void)removeTileSource:(RMTileSource *)tileSource
{
    RMProjectedPoint centerPoint = [self centerProjectedPoint];
    
    [_tileSourcesContainer removeTileSource:tileSource];
    
    if ([_tileSourcesContainer.tileSources count] == 0)
    {
        _constrainMovement = NO;
    }
    else
    {
        [self setTileSourcesConstraintsFromLatitudeLongitudeBoundingBox:[_tileSourcesContainer latitudeLongitudeBoundingBox]];
    }
    
    // Remove the map layer
    RMMapTiledLayerView *tileSourceTiledLayerView = nil;
    
    for (RMMapTiledLayerView *tiledLayerView in _tiledLayersSuperview.subviews)
    {
        if (tiledLayerView.tileSource == tileSource)
        {
            tileSourceTiledLayerView = tiledLayerView;
            break;
        }
    }
    
    tileSourceTiledLayerView.layer.contents = nil;
    [tileSourceTiledLayerView removeFromSuperview];  tileSourceTiledLayerView = nil;
    
    [self setCenterProjectedPoint:centerPoint animated:NO];
}

- (void)removeTileSourceAtIndex:(NSUInteger)index
{
    RMProjectedPoint centerPoint = [self centerProjectedPoint];
    
    [_tileSourcesContainer removeTileSourceAtIndex:index];
    
    if ([_tileSourcesContainer.tileSources count] == 0)
    {
        _constrainMovement = NO;
    }
    else
    {
        [self setTileSourcesConstraintsFromLatitudeLongitudeBoundingBox:[_tileSourcesContainer latitudeLongitudeBoundingBox]];
    }
    
    // Remove the map layer
    RMMapTiledLayerView *tileSourceTiledLayerView = [_tiledLayersSuperview.subviews objectAtIndex:index];
    
    tileSourceTiledLayerView.layer.contents = nil;
    [tileSourceTiledLayerView removeFromSuperview];  tileSourceTiledLayerView = nil;
    
    [self setCenterProjectedPoint:centerPoint animated:NO];
}

- (void)moveTileSourceAtIndex:(NSUInteger)fromIndex toIndex:(NSUInteger)toIndex
{
    if (fromIndex == toIndex)
        return;
    
    if (fromIndex >= [[_tileSourcesContainer tileSources] count])
        return;
    
    RMProjectedPoint centerPoint = [self centerProjectedPoint];
    
    [_tileSourcesContainer moveTileSourceAtIndex:fromIndex toIndex:toIndex];
    
    // Move the map layer
    [_tiledLayersSuperview exchangeSubviewAtIndex:fromIndex withSubviewAtIndex:toIndex];
    
    [self setCenterProjectedPoint:centerPoint animated:NO];
}

- (void)setHidden:(BOOL)isHidden forTileSource:(RMTileSource *)tileSource
{
    NSArray *tileSources = [self tileSources];
    
    [tileSources enumerateObjectsUsingBlock:^(RMTileSource *currentTileSource, NSUInteger index, BOOL *stop)
     {
         if (tileSource == currentTileSource)
         {
             [self setHidden:isHidden forTileSourceAtIndex:index];
             *stop = YES;
         }
     }];
}

- (void)setHidden:(BOOL)isHidden forTileSourceAtIndex:(NSUInteger)index
{
    if (index >= [_tiledLayersSuperview.subviews count])
        return;
    
    ((RMMapTiledLayerView *)[_tiledLayersSuperview.subviews objectAtIndex:index]).hidden = isHidden;
}

- (void)reloadTileSource:(RMTileSource *)tileSource
{
    // Reload the map layer
    for (RMMapTiledLayerView *tiledLayerView in _tiledLayersSuperview.subviews)
    {
        if (tiledLayerView.tileSource == tileSource)
        {
            //            tiledLayerView.layer.contents = nil;
            [tiledLayerView setNeedsDisplay:YES];
            break;
        }
    }
}

- (void)reloadTileSourceAtIndex:(NSUInteger)index
{
    if (index >= [_tiledLayersSuperview.subviews count])
        return;
    
    // Reload the map layer
    RMMapTiledLayerView *tiledLayerView = [_tiledLayersSuperview.subviews objectAtIndex:index];
    //    tiledLayerView.layer.contents = nil;
    [tiledLayerView setNeedsDisplay:YES];
}

#pragma mark - Properties

- (NSView *)backgroundView
{
    return _backgroundView;
}

- (void)setBackgroundView:(NSView *)aView
{
    if (_backgroundView == aView)
        return;
    
    if (_backgroundView != nil)
    {
        [_backgroundView removeFromSuperview];
    }
    
    _backgroundView = aView;
    if (_backgroundView == nil)
        return;
    
    _backgroundView.frame = [self bounds];
    
    [self insertSubview:_backgroundView atIndex:0];
}

- (void)setBackgroundImage:(NSImage *)backgroundImage
{
    if (backgroundImage)
    {
        [self setBackgroundView:[[NSView alloc] initWithFrame:self.bounds]];
        self.backgroundView.layer.contents = (id)backgroundImage.CGImage;
    }
    else
    {
        [self setBackgroundView:nil];
    }
}

- (double)metersPerPixel
{
    return _metersPerPixel;
}

- (void)setMetersPerPixel:(double)newMetersPerPixel
{
    [self setMetersPerPixel:newMetersPerPixel animated:YES];
}

- (void)setMetersPerPixel:(double)newMetersPerPixel animated:(BOOL)animated
{
    double factor = self.metersPerPixel / newMetersPerPixel;
    
    [self zoomByFactor:factor near:CGPointMake(self.bounds.size.width/2.0, self.bounds.size.height/2.0) animated:animated];
}

- (double)scaledMetersPerPixel
{
    return _metersPerPixel / _screenScale;
}

// From http://stackoverflow.com/questions/610193/calculating-pixel-size-on-an-iphone
#define kiPhone3MillimeteresPerPixel 0.1558282
#define kiPhone4MillimetersPerPixel (0.0779 * 2.0)

#define iPad1MillimetersPerPixel 0.1924
#define iPad3MillimetersPerPixel (0.09621 * 2.0)

- (double)scaleDenominator
{
    double iphoneMillimetersPerPixel;
    
    BOOL deviceIsIPhone = ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPhone);
    BOOL deviceHasRetinaDisplay = (_screenScale > 1.0);
    
    if (deviceHasRetinaDisplay)
        iphoneMillimetersPerPixel = (deviceIsIPhone ? kiPhone4MillimetersPerPixel : iPad3MillimetersPerPixel);
    else
        iphoneMillimetersPerPixel = (deviceIsIPhone ? kiPhone3MillimeteresPerPixel : iPad1MillimetersPerPixel);
    
    return ((_metersPerPixel * 1000.0) / iphoneMillimetersPerPixel);
}

- (void)setMinZoom:(float)newMinZoom
{
    float boundingDimension = fmaxf(self.bounds.size.width, self.bounds.size.height);
    float tileSideLength    = _tileSourcesContainer.tileSideLength / 2;
    if (tileSideLength != 0) {
        float clampedMinZoom    = log2(boundingDimension / tileSideLength);
        clampedMinZoom = ceilf(clampedMinZoom);
        if (newMinZoom < clampedMinZoom)
            newMinZoom = clampedMinZoom;
        
        if (newMinZoom < 0.0)
            newMinZoom = 0.0;
    }
    _minZoom = newMinZoom;
    
    RMLog(@"New minZoom:%f", newMinZoom);
    
    _mapScrollView.minimumZoomScale = exp2f(newMinZoom);
}

- (float)tileSourcesMinZoom
{
    return self.tileSourcesContainer.minZoom;
}

- (void)setTileSourcesMinZoom:(float)tileSourcesMinZoom
{
    tileSourcesMinZoom = ceilf(tileSourcesMinZoom) - 0.99;
    
    if ( ! self.adjustTilesForRetinaDisplay && _screenScale > 1.0)
        tileSourcesMinZoom -= 1.0;
    
    [self setMinZoom:tileSourcesMinZoom];
}

- (void)setMaxZoom:(float)newMaxZoom
{
    if (newMaxZoom < 0.0)
        newMaxZoom = 0.0;
    
    _maxZoom = newMaxZoom;
    
    //    RMLog(@"New maxZoom:%f", newMaxZoom);
    
    _mapScrollView.maximumZoomScale = exp2f(newMaxZoom);
}

- (float)tileSourcesMaxZoom
{
    return self.tileSourcesContainer.maxZoom;
}

- (void)setTileSourcesMaxZoom:(float)tileSourcesMaxZoom
{
    tileSourcesMaxZoom = floorf(tileSourcesMaxZoom);
    
    if ( ! self.adjustTilesForRetinaDisplay && _screenScale > 1.0)
        tileSourcesMaxZoom -= 1.0;
    
    [self setMaxZoom:tileSourcesMaxZoom];
}

- (float)zoom
{
    return _zoom;
}

// if #zoom is outside of range #minZoom to #maxZoom, zoom level is clamped to that range.
- (void)setZoom:(float)newZoom
{
    if (_zoom == newZoom)
        return;
    
    [self registerZoomEventByUser:NO];
    
    _zoom = (newZoom > _maxZoom) ? _maxZoom : newZoom;
    _zoom = (_zoom < _minZoom) ? _minZoom : _zoom;
    
//        RMLog(@"New zoom:%f", _zoom);

    _mapScrollView.zoomScale = exp2f(_zoom);
    [self updateMetersPerPixel];
    
    [self completeZoomEventAfterDelay:0];
}

- (float)tileSourcesZoom
{
    float zoom = ceilf(_zoom);
    
    if ( ! self.adjustTilesForRetinaDisplay && _screenScale > 1.0)
        zoom += 1.0;
    
    return zoom;
}

- (void)setTileSourcesZoom:(float)tileSourcesZoom
{
    tileSourcesZoom = floorf(tileSourcesZoom);
    
    if ( ! self.adjustTilesForRetinaDisplay && _screenScale > 1.0)
        tileSourcesZoom -= 1.0;
    
    [self setZoom:tileSourcesZoom];
}

- (void)setClusteringEnabled:(BOOL)doEnableClustering
{
    _clusteringEnabled = doEnableClustering;
    
    [self correctPositionOfAllAnnotations];
}

//TODO: scroll view delegate
#if 0
- (void)setDecelerationMode:(RMMapDecelerationMode)aDecelerationMode
{
    _decelerationMode = aDecelerationMode;
    
    float decelerationRate = 0.0;
    
    if (aDecelerationMode == RMMapDecelerationNormal)
        decelerationRate = UIScrollViewDecelerationRateNormal;
    else if (aDecelerationMode == RMMapDecelerationFast)
        decelerationRate = UIScrollViewDecelerationRateFast;
    
    [_mapScrollView setDecelerationRate:decelerationRate];
}

- (BOOL)draggingEnabled
{
    return _draggingEnabled;
}

- (void)setDraggingEnabled:(BOOL)enableDragging
{
    _draggingEnabled = enableDragging;
    _mapScrollView.scrollEnabled = enableDragging;
}

- (BOOL)bouncingEnabled
{
    return _bouncingEnabled;
}

- (void)setBouncingEnabled:(BOOL)enableBouncing
{
    _bouncingEnabled = enableBouncing;
    _mapScrollView.bounces = enableBouncing;
    _mapScrollView.bouncesZoom = enableBouncing;
}
#endif

- (void)setAdjustTilesForRetinaDisplay:(BOOL)doAdjustTilesForRetinaDisplay
{
    if (_adjustTilesForRetinaDisplay == doAdjustTilesForRetinaDisplay)
        return;
    
    _adjustTilesForRetinaDisplay = doAdjustTilesForRetinaDisplay;
    
    RMProjectedPoint centerPoint = [self centerProjectedPoint];
    
    [self createMapView];
    
    [self setCenterProjectedPoint:centerPoint animated:NO];
}

- (float)adjustedZoomForRetinaDisplay
{
    if (!self.adjustTilesForRetinaDisplay && _screenScale > 1.0)
        return [self zoom] + 1.0;
    
    return [self zoom];
}

- (RMProjection *)projection
{
    return _projection;
}

- (RMFractalTileProjection *)mercatorToTileProjection
{
    return _mercatorToTileProjection;
}

- (void)setDebugTiles:(BOOL)shouldDebug;
{
    _debugTiles = shouldDebug;
    
    for (RMMapTiledLayerView *tiledLayerView in _tiledLayersSuperview.subviews)
    {
        tiledLayerView.layer.contents = nil;
        [tiledLayerView.layer setNeedsDisplay];
    }
}

- (void)setShowLogoBug:(BOOL)showLogoBug
{
    if (showLogoBug && ! _logoBug)
    {
        _logoBug = [[NSImageView alloc] init];

        _logoBug.image = [NSImage imageNamed:@"mapbox.png"];
        
        _logoBug.frame = CGRectMake(8, self.bounds.size.height - _logoBug.bounds.size.height - 4, _logoBug.bounds.size.width, _logoBug.bounds.size.height);
//TODO: fix me
//        _logoBug.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleRightMargin;
        
        [self addSubview:_logoBug];
    }
    else if ( ! showLogoBug && _logoBug)
    {
        [_logoBug removeFromSuperview];
    }
    
    _showLogoBug = showLogoBug;
}

#pragma mark -
#pragma mark LatLng/Pixel translation functions

- (CGPoint)projectedPointToPixel:(RMProjectedPoint)projectedPoint
{
    RMProjectedRect planetBounds = _projection.planetBounds;
    RMProjectedPoint normalizedProjectedPoint;
	normalizedProjectedPoint.x = projectedPoint.x + fabs(planetBounds.origin.x);
	normalizedProjectedPoint.y = -(projectedPoint.y + fabs(planetBounds.origin.y));
    
    // \bug: There is a rounding error here for high zoom levels
    CGPoint projectedPixel = CGPointMake((normalizedProjectedPoint.x / _metersPerPixel) - _mapScrollView.contentOffset.x, (_mapScrollView.contentSize.height - (normalizedProjectedPoint.y / _metersPerPixel)) - _mapScrollView.contentOffset.y);
    
    RMLog(@"pointToPixel: {%f,%f} -> {%f,%f}", projectedPoint.x, projectedPoint.y, projectedPixel.x, projectedPixel.y);
    
    return projectedPixel;
}

- (CGPoint)coordinateToPixel:(CLLocationCoordinate2D)coordinate
{
    return [self projectedPointToPixel:[_projection coordinateToProjectedPoint:coordinate]];
}

- (RMProjectedPoint)pixelToProjectedPoint:(CGPoint)pixelCoordinate
{
    RMProjectedRect planetBounds = _projection.planetBounds;
    RMProjectedPoint normalizedProjectedPoint;
    normalizedProjectedPoint.x = ((pixelCoordinate.x + _mapScrollView.contentOffset.x) * _metersPerPixel) - fabs(planetBounds.origin.x);
//    normalizedProjectedPoint.y = ((_mapScrollView.contentSize.height - _mapScrollView.contentOffset.y - pixelCoordinate.y) * _metersPerPixel) - fabs(planetBounds.origin.y);
    normalizedProjectedPoint.y = ((pixelCoordinate.y + _mapScrollView.contentOffset.y ) * _metersPerPixel) - fabs(planetBounds.origin.y);
    
    //normalizedProjectedPoint.y = -normalizedProjectedPoint.y;
    
//    RMLog(@"meters per pixel: %f", _metersPerPixel);
//    RMLog(@"pixelToPoint: {%f,%f} -> {%f,%f}", pixelCoordinate.x, pixelCoordinate.y, normalizedProjectedPoint.x, normalizedProjectedPoint.y);
//    RMLog(@"contentOFfset: {%f, %f}", _mapScrollView.contentOffset.x, _mapScrollView.contentOffset.y);
    return normalizedProjectedPoint;
}

- (CLLocationCoordinate2D)pixelToCoordinate:(CGPoint)pixelCoordinate
{
    return [_projection projectedPointToCoordinate:[self pixelToProjectedPoint:pixelCoordinate]];
}

- (RMProjectedPoint)coordinateToProjectedPoint:(CLLocationCoordinate2D)coordinate
{
    return [_projection coordinateToProjectedPoint:coordinate];
}

- (CLLocationCoordinate2D)projectedPointToCoordinate:(RMProjectedPoint)projectedPoint
{
    return [_projection projectedPointToCoordinate:projectedPoint];
}

- (RMProjectedSize)viewSizeToProjectedSize:(CGSize)screenSize
{
    return RMProjectedSizeMake(screenSize.width * _metersPerPixel, screenSize.height * _metersPerPixel);
}

- (CGSize)projectedSizeToViewSize:(RMProjectedSize)projectedSize
{
    return CGSizeMake(projectedSize.width / _metersPerPixel, projectedSize.height / _metersPerPixel);
}

- (RMProjectedPoint)projectedOrigin
{
    CGPoint origin = CGPointMake(_mapScrollView.contentOffset.x, _mapScrollView.contentSize.height - _mapScrollView.contentOffset.y);
    
    RMProjectedRect planetBounds = _projection.planetBounds;
    RMProjectedPoint normalizedProjectedPoint;
    normalizedProjectedPoint.x = (origin.x * _metersPerPixel) - fabs(planetBounds.origin.x);
    normalizedProjectedPoint.y = (origin.y * _metersPerPixel) - fabs(planetBounds.origin.y);
    
    RMLog(@"projectedOrigin: {%f,%f}", normalizedProjectedPoint.x, normalizedProjectedPoint.y);
    
    return normalizedProjectedPoint;
}

- (RMProjectedSize)projectedViewSize
{
    return RMProjectedSizeMake(self.bounds.size.width * _metersPerPixel, self.bounds.size.height * _metersPerPixel);
}

- (CLLocationCoordinate2D)normalizeCoordinate:(CLLocationCoordinate2D)coordinate
{
	if (coordinate.longitude > 180.0)
        coordinate.longitude -= 360.0;
    
	coordinate.longitude /= 360.0;
	coordinate.longitude += 0.5;
	coordinate.latitude = 0.5 - ((log(tan((M_PI_4) + ((0.5 * M_PI * coordinate.latitude) / 180.0))) / M_PI) / 2.0);
    
	return coordinate;
}

- (RMTile)tileWithCoordinate:(CLLocationCoordinate2D)coordinate andZoom:(int)tileZoom
{
	int scale = (1<<tileZoom);
	CLLocationCoordinate2D normalizedCoordinate = [self normalizeCoordinate:coordinate];
    
	RMTile returnTile;
	returnTile.x = (int)(normalizedCoordinate.longitude * scale);
	returnTile.y = (int)(normalizedCoordinate.latitude * scale);
	returnTile.zoom = tileZoom;
    
	return returnTile;
}

- (RMSphericalTrapezium)latitudeLongitudeBoundingBoxForTile:(RMTile)aTile
{
    RMProjectedRect planetBounds = _projection.planetBounds;
    
    double scale = (1<<aTile.zoom);
    double tileSideLength = [_tileSourcesContainer tileSideLength];
    double tileMetersPerPixel = planetBounds.size.width / (tileSideLength * scale);
    
    CGPoint bottomLeft = CGPointMake(aTile.x * tileSideLength, (scale - aTile.y - 1) * tileSideLength);
    
    RMProjectedRect normalizedProjectedRect;
    normalizedProjectedRect.origin.x = (bottomLeft.x * tileMetersPerPixel) - fabs(planetBounds.origin.x);
    normalizedProjectedRect.origin.y = (bottomLeft.y * tileMetersPerPixel) - fabs(planetBounds.origin.y);
    normalizedProjectedRect.size.width = tileSideLength * tileMetersPerPixel;
    normalizedProjectedRect.size.height = tileSideLength * tileMetersPerPixel;
    
    RMSphericalTrapezium boundingBox;
    boundingBox.southWest = [self projectedPointToCoordinate:
                             RMProjectedPointMake(normalizedProjectedRect.origin.x,
                                                  normalizedProjectedRect.origin.y)];
    boundingBox.northEast = [self projectedPointToCoordinate:
                             RMProjectedPointMake(normalizedProjectedRect.origin.x + normalizedProjectedRect.size.width,
                                                  normalizedProjectedRect.origin.y + normalizedProjectedRect.size.height)];
    
    RMLog(@"Bounding box for tile (%d,%d) at zoom %d: {%f,%f} {%f,%f)", aTile.x, aTile.y, aTile.zoom, boundingBox.southWest.longitude, boundingBox.southWest.latitude, boundingBox.northEast.longitude, boundingBox.northEast.latitude);
    
    return boundingBox;
}

#pragma mark -
#pragma mark Bounds

- (RMSphericalTrapezium)latitudeLongitudeBoundingBox
{
    return [self latitudeLongitudeBoundingBoxFor:[self bounds]];
}

- (RMSphericalTrapezium)latitudeLongitudeBoundingBoxFor:(CGRect)rect
{
    RMSphericalTrapezium boundingBox;
    CGPoint northwestScreen = rect.origin;
    
    CGPoint southeastScreen;
    southeastScreen.x = rect.origin.x + rect.size.width;
    southeastScreen.y = rect.origin.y + rect.size.height;
    
    CGPoint northeastScreen, southwestScreen;
    northeastScreen.x = southeastScreen.x;
    northeastScreen.y = northwestScreen.y;
    southwestScreen.x = northwestScreen.x;
    southwestScreen.y = southeastScreen.y;
    
    CLLocationCoordinate2D northeastLL, northwestLL, southeastLL, southwestLL;
    northeastLL = [self pixelToCoordinate:northeastScreen];
    northwestLL = [self pixelToCoordinate:northwestScreen];
    southeastLL = [self pixelToCoordinate:southeastScreen];
    southwestLL = [self pixelToCoordinate:southwestScreen];
    
    boundingBox.northEast.latitude = fmax(northeastLL.latitude, northwestLL.latitude);
    boundingBox.southWest.latitude = fmin(southeastLL.latitude, southwestLL.latitude);
    
    // westerly computations:
    // -179, -178 -> -179 (min)
    // -179, 179  -> 179 (max)
    if (fabs(northwestLL.longitude - southwestLL.longitude) <= kMaxLong)
        boundingBox.southWest.longitude = fmin(northwestLL.longitude, southwestLL.longitude);
    else
        boundingBox.southWest.longitude = fmax(northwestLL.longitude, southwestLL.longitude);
    
    if (fabs(northeastLL.longitude - southeastLL.longitude) <= kMaxLong)
        boundingBox.northEast.longitude = fmax(northeastLL.longitude, southeastLL.longitude);
    else
        boundingBox.northEast.longitude = fmin(northeastLL.longitude, southeastLL.longitude);
    
    return boundingBox;
}

#pragma mark -
#pragma mark Annotations

- (void)correctScreenPosition:(RMAnnotation *)annotation animated:(BOOL)animated
{
    RMProjectedRect planetBounds = _projection.planetBounds;
	RMProjectedPoint normalizedProjectedPoint;
	normalizedProjectedPoint.x = annotation.projectedLocation.x + fabs(planetBounds.origin.x);
	normalizedProjectedPoint.y = annotation.projectedLocation.y + fabs(planetBounds.origin.y);
    
    CGPoint contentOffset = _mapScrollView.contentOffset;
    CGSize contentSize = _mapScrollView.contentSize;
    
    CGPoint newPosition = CGPointMake((normalizedProjectedPoint.x / _metersPerPixel) - _mapScrollView.contentOffset.x,
                                       (normalizedProjectedPoint.y / _metersPerPixel) - _mapScrollView.contentOffset.y);
        
//    RMLog(@"Change annotation at {%f,%f} in mapView {%f,%f}", annotation.position.x, annotation.position.y, _mapScrollView.contentSize.width, _mapScrollView.contentSize.height);
    
    [annotation setPosition:newPosition animated:animated];
}

- (void)correctPositionOfAllAnnotationsIncludingInvisibles:(BOOL)correctAllAnnotations animated:(BOOL)animated
{
//    NSLog(@"correctPositionOfAllAnnotationsIncludingInvisibles %d", animated);
    // Prevent blurry movements
    [CATransaction begin];
    
    // Synchronize marker movement with the map scroll view
    if (animated && !_mapScrollView.isZooming)
    {
        [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
        [CATransaction setAnimationDuration:0.30];
    }
    else
    {
        [CATransaction setValue:(id)kCFBooleanTrue forKey:kCATransactionDisableActions];
    }
    
    _accumulatedDelta.x = 0.0;
    _accumulatedDelta.y = 0.0;
    [_overlayView moveLayersBy:_accumulatedDelta];
    
    if (self.quadTree)
    {
        if (!correctAllAnnotations || _mapScrollViewIsZooming)
        {
            for (RMAnnotation *annotation in _visibleAnnotations)
                [self correctScreenPosition:annotation animated:animated];
            
            //            RMLog(@"%d annotations corrected", [visibleAnnotations count]);
            
            [CATransaction commit];
            
            return;
        }
        
        double boundingBoxBuffer = (kZoomRectPixelBuffer * _metersPerPixel);
        
        RMProjectedRect boundingBox = self.projectedBounds;
        boundingBox.origin.x -= boundingBoxBuffer;
        boundingBox.origin.y -= boundingBoxBuffer;
        boundingBox.size.width += (2.0 * boundingBoxBuffer);
        boundingBox.size.height += (2.0 * boundingBoxBuffer);
        
        NSArray *annotationsToCorrect = [self.quadTree annotationsInProjectedRect:boundingBox
                                                         createClusterAnnotations:self.clusteringEnabled
                                                         withProjectedClusterSize:RMProjectedSizeMake(self.clusterAreaSize.width * _metersPerPixel, self.clusterAreaSize.height * _metersPerPixel)
                                                    andProjectedClusterMarkerSize:RMProjectedSizeMake(self.clusterMarkerSize.width * _metersPerPixel, self.clusterMarkerSize.height * _metersPerPixel)
                                                                findGravityCenter:self.positionClusterMarkersAtTheGravityCenter];
        NSMutableSet *previousVisibleAnnotations = [[NSMutableSet alloc] initWithSet:_visibleAnnotations];
        
        for (RMAnnotation *annotation in annotationsToCorrect)
        {
            if (annotation.layer == nil && delegateRespondsTo.layerForAnnotation)
                annotation.layer = [_delegate mapView:self layerForAnnotation:annotation];
            
            if (annotation.layer == nil)
                continue;
            
            if ([annotation.layer isKindOfClass:[RMMarker class]] && ! annotation.isUserLocationAnnotation)
                annotation.layer.transform = _annotationTransform;
            
            // Use the zPosition property to order the layer hierarchy
            if ( ! [_visibleAnnotations containsObject:annotation])
            {
                [_overlayView addSublayer:annotation.layer];
                [_visibleAnnotations addObject:annotation];
            }
            
            [self correctScreenPosition:annotation animated:animated];
            
            [previousVisibleAnnotations removeObject:annotation];
        }
        
        for (RMAnnotation *annotation in previousVisibleAnnotations)
        {
            if ( ! annotation.isUserLocationAnnotation)
            {
                if (delegateRespondsTo.willHideLayerForAnnotation)
                    [_delegate mapView:self willHideLayerForAnnotation:annotation];
                
                annotation.layer = nil;
                
                if (delegateRespondsTo.didHideLayerForAnnotation)
                    [_delegate mapView:self didHideLayerForAnnotation:annotation];
                
                [_visibleAnnotations removeObject:annotation];
            }
        }
        
        previousVisibleAnnotations = nil;
        
        //        RMLog(@"%d annotations on screen, %d total", [overlayView sublayersCount], [annotations count]);
    }
    else
    {
        CALayer *lastLayer = nil;
        
        @synchronized (_annotations)
        {
            if (correctAllAnnotations)
            {
                for (RMAnnotation *annotation in _annotations)
                {
                    [self correctScreenPosition:annotation animated:animated];
                    
                    if ([annotation isAnnotationWithinBounds:[self bounds]])
                    {
                        if (annotation.layer == nil && delegateRespondsTo.layerForAnnotation)
                            annotation.layer = [_delegate mapView:self layerForAnnotation:annotation];
                        
                        if (annotation.layer == nil)
                            continue;
                        
                        if ([annotation.layer isKindOfClass:[RMMarker class]] && ! annotation.isUserLocationAnnotation)
                            annotation.layer.transform = _annotationTransform;
                        
                        if (![_visibleAnnotations containsObject:annotation])
                        {
                            if (!lastLayer)
                                [_overlayView insertSublayer:annotation.layer atIndex:0];
                            else
                                [_overlayView insertSublayer:annotation.layer above:lastLayer];
                            
                            [_visibleAnnotations addObject:annotation];
                        }
                        
                        lastLayer = annotation.layer;
                    }
                    else
                    {
                        if ( ! annotation.isUserLocationAnnotation)
                        {
                            if (delegateRespondsTo.willHideLayerForAnnotation)
                                [_delegate mapView:self willHideLayerForAnnotation:annotation];
                            
                            annotation.layer = nil;
                            [_visibleAnnotations removeObject:annotation];
                            
                            if (delegateRespondsTo.didHideLayerForAnnotation)
                                [_delegate mapView:self didHideLayerForAnnotation:annotation];
                        }
                    }
                }
                //                RMLog(@"%d annotations on screen, %d total", [overlayView sublayersCount], [annotations count]);
            }
            else
            {
                for (RMAnnotation *annotation in _visibleAnnotations)
                    [self correctScreenPosition:annotation animated:animated];
                
                //                RMLog(@"%d annotations corrected", [visibleAnnotations count]);
            }
        }
    }
    
    [self correctOrderingOfAllAnnotations];
    
    [CATransaction commit];
}

- (void)correctPositionOfAllAnnotations
{
    [self correctPositionOfAllAnnotationsIncludingInvisibles:YES animated:NO];
}

- (void)correctOrderingOfAllAnnotations
{
    if ( ! _orderMarkersByYPosition)
        return;

    // sort annotation layer z-indexes so that they overlap properly
    //
    NSMutableArray *sortedAnnotations = [NSMutableArray arrayWithArray:[_visibleAnnotations allObjects]];
    
    [sortedAnnotations filterUsingPredicate:[NSPredicate predicateWithFormat:@"isUserLocationAnnotation = NO"]];
    
    [sortedAnnotations sortUsingComparator:^(id obj1, id obj2)
     {
         RMAnnotation *annotation1 = (RMAnnotation *)obj1;
         RMAnnotation *annotation2 = (RMAnnotation *)obj2;
         
         // clusters above/below non-clusters (based on _orderClusterMarkersAboveOthers)
         //
         if (   annotation1.isClusterAnnotation && ! annotation2.isClusterAnnotation)
             return (_orderClusterMarkersAboveOthers ? NSOrderedDescending : NSOrderedAscending);
         
         if ( ! annotation1.isClusterAnnotation &&   annotation2.isClusterAnnotation)
             return (_orderClusterMarkersAboveOthers ? NSOrderedAscending : NSOrderedDescending);
         
         // markers above shapes
         //
         if (   [annotation1.layer isKindOfClass:[RMMarker class]] && ! [annotation2.layer isKindOfClass:[RMMarker class]])
             return NSOrderedDescending;
         
         if ( ! [annotation1.layer isKindOfClass:[RMMarker class]] &&   [annotation2.layer isKindOfClass:[RMMarker class]])
             return NSOrderedAscending;
         
         // the rest in increasing y-position
         //
         CGPoint obj1Point = [self convertPoint:annotation1.position fromView:_overlayView];
         CGPoint obj2Point = [self convertPoint:annotation2.position fromView:_overlayView];
         
         if (obj1Point.y > obj2Point.y)
             return NSOrderedDescending;
         
         if (obj1Point.y < obj2Point.y)
             return NSOrderedAscending;
         
         return NSOrderedSame;
     }];
    
    for (CGFloat i = 0; i < [sortedAnnotations count]; i++)
        ((RMAnnotation *)[sortedAnnotations objectAtIndex:i]).layer.zPosition = (CGFloat)i;
    
    // bring any active callout annotation to the front
    //
    //TODO: fix me
    /*
    if (_currentAnnotation)
        _currentAnnotation.layer.zPosition = _currentCallout.layer.zPosition = MAXFLOAT;
     */
}

- (NSArray *)annotations
{
    return [_annotations allObjects];
}

- (NSArray *)visibleAnnotations
{
    return [_visibleAnnotations allObjects];
}

- (void)addAnnotation:(RMAnnotation *)annotation
{
    @synchronized (_annotations)
    {
        if ([_annotations containsObject:annotation])
            return;
        
        [_annotations addObject:annotation];
        [self.quadTree addAnnotation:annotation];
    }
    
    if (_clusteringEnabled)
    {
        [self correctPositionOfAllAnnotations];
    }
    else
    {
        [self correctScreenPosition:annotation animated:NO];
        
        if (annotation.layer == nil && [annotation isAnnotationOnScreen] && delegateRespondsTo.layerForAnnotation)
            annotation.layer = [_delegate mapView:self layerForAnnotation:annotation];
        
        if (annotation.layer)
        {
            [_overlayView addSublayer:annotation.layer];
            [_visibleAnnotations addObject:annotation];
        }
        
        [self correctOrderingOfAllAnnotations];
    }
}

- (void)addAnnotations:(NSArray *)newAnnotations
{
    @synchronized (_annotations)
    {
        [_annotations addObjectsFromArray:newAnnotations];
        [self.quadTree addAnnotations:newAnnotations];
    }
    
    [self correctPositionOfAllAnnotationsIncludingInvisibles:YES animated:NO];
}

- (void)removeAnnotation:(RMAnnotation *)annotation
{
    @synchronized (_annotations)
    {
        [_annotations removeObject:annotation];
        [_visibleAnnotations removeObject:annotation];
    }
    
    [self.quadTree removeAnnotation:annotation];
    
    // Remove the layer from the screen
    annotation.layer = nil;
}

- (void)removeAnnotations:(NSArray *)annotationsToRemove
{
    @synchronized (_annotations)
    {
        for (RMAnnotation *annotation in annotationsToRemove)
        {
            if ( ! annotation.isUserLocationAnnotation)
            {
                [_annotations removeObject:annotation];
                [_visibleAnnotations removeObject:annotation];
                [self.quadTree removeAnnotation:annotation];
                annotation.layer = nil;
            }
        }
    }
    
    [self correctPositionOfAllAnnotations];
}

- (void)removeAllAnnotations
{
    [self removeAnnotations:[_annotations allObjects]];
}

- (CGPoint)mapPositionForAnnotation:(RMAnnotation *)annotation
{
    [self correctScreenPosition:annotation animated:NO];
    return annotation.position;
}

#pragma mark -
#pragma mark User Location

- (void)setShowsUserLocation:(BOOL)newShowsUserLocation
{
    if (newShowsUserLocation == _showsUserLocation)
        return;
    
    _showsUserLocation = newShowsUserLocation;
    
    if (newShowsUserLocation)
    {
        if (delegateRespondsTo.willStartLocatingUser)
            [_delegate mapViewWillStartLocatingUser:self];
        
        self.userLocation = [RMUserLocation annotationWithMapView:self coordinate:CLLocationCoordinate2DMake(MAXFLOAT, MAXFLOAT) andTitle:nil];
        
        _locationManager = [CLLocationManager new];
//        _locationManager.headingFilter = 5.0;
        _locationManager.delegate = self;
        [_locationManager startUpdatingLocation];
    }
    else
    {
        [_locationManager stopUpdatingLocation];
//        [_locationManager stopUpdatingHeading];
        _locationManager.delegate = nil;
        _locationManager = nil;
        
        if (delegateRespondsTo.didStopLocatingUser)
            [_delegate mapViewDidStopLocatingUser:self];
        
        [self setUserTrackingMode:RMUserTrackingModeNone animated:YES];
        
        for (RMAnnotation *annotation in [NSArray arrayWithObjects:_trackingHaloAnnotation, _accuracyCircleAnnotation, self.userLocation, nil])
            [self removeAnnotation:annotation];
        
        _trackingHaloAnnotation = nil;
        _accuracyCircleAnnotation = nil;
        
        self.userLocation = nil;
    }
}

- (void)setUserLocation:(RMUserLocation *)newUserLocation
{
    if ( ! [newUserLocation isEqual:_userLocation])
        _userLocation = newUserLocation;
}

- (BOOL)isUserLocationVisible
{
    if (self.userLocation)
    {
        CGPoint locationPoint = [self mapPositionForAnnotation:self.userLocation];
        
        CGRect locationRect = CGRectMake(locationPoint.x - self.userLocation.location.horizontalAccuracy,
                                         locationPoint.y - self.userLocation.location.horizontalAccuracy,
                                         self.userLocation.location.horizontalAccuracy * 2,
                                         self.userLocation.location.horizontalAccuracy * 2);
        
        return CGRectIntersectsRect([self bounds], locationRect);
    }
    
    return NO;
}

- (void)setUserTrackingMode:(RMUserTrackingMode)mode
{
    [self setUserTrackingMode:mode animated:YES];
}

- (void)setUserTrackingMode:(RMUserTrackingMode)mode animated:(BOOL)animated
{
    if (mode == _userTrackingMode)
        return;
    
    if (mode == RMUserTrackingModeFollowWithHeading && ! CLLocationCoordinate2DIsValid(self.userLocation.coordinate))
        mode = RMUserTrackingModeNone;
    
    _userTrackingMode = mode;
 //TODO: check
#if 0
    switch (_userTrackingMode)
    {
        case RMUserTrackingModeNone:
        default:
        {
            [_locationManager stopUpdatingHeading];
            
            [CATransaction setAnimationDuration:0.5];
            [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
            
            [UIView animateWithDuration:(animated ? 0.5 : 0.0)
                                  delay:0.0
                                options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationCurveEaseInOut
                             animations:^(void)
             {
                 _mapTransform = CGAffineTransformIdentity;
                 _annotationTransform = CATransform3DIdentity;
                 
                 _mapScrollView.transform = _mapTransform;
                 _overlayView.transform   = _mapTransform;
                 
                 for (RMAnnotation *annotation in _annotations)
                     if ([annotation.layer isKindOfClass:[RMMarker class]] && ! annotation.isUserLocationAnnotation)
                         annotation.layer.transform = _annotationTransform;
             }
                             completion:nil];
            
            [CATransaction commit];
            
            if (_userLocationTrackingView || _userHeadingTrackingView || _userHaloTrackingView)
            {
                [_userLocationTrackingView removeFromSuperview]; _userLocationTrackingView = nil;
                [_userHeadingTrackingView removeFromSuperview]; _userHeadingTrackingView = nil;
                [_userHaloTrackingView removeFromSuperview]; _userHaloTrackingView = nil;
            }
            
            self.userLocation.layer.hidden = NO;
            
            break;
        }
        case RMUserTrackingModeFollow:
        {
            self.showsUserLocation = YES;
            
            [_locationManager stopUpdatingHeading];
            
            if (self.userLocation)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                [self locationManager:_locationManager didUpdateToLocation:self.userLocation.location fromLocation:self.userLocation.location];
#pragma clang diagnostic pop
            
            if (_userLocationTrackingView || _userHeadingTrackingView || _userHaloTrackingView)
            {
                [_userLocationTrackingView removeFromSuperview]; _userLocationTrackingView = nil;
                [_userHeadingTrackingView removeFromSuperview]; _userHeadingTrackingView = nil;
                [_userHaloTrackingView removeFromSuperview]; _userHaloTrackingView = nil;
            }
            
            [CATransaction setAnimationDuration:0.5];
            [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
            
            [UIView animateWithDuration:(animated ? 0.5 : 0.0)
                                  delay:0.0
                                options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationCurveEaseInOut
                             animations:^(void)
             {
                 _mapTransform = CGAffineTransformIdentity;
                 _annotationTransform = CATransform3DIdentity;
                 
                 _mapScrollView.transform = _mapTransform;
                 _overlayView.transform   = _mapTransform;
                 
                 for (RMAnnotation *annotation in _annotations)
                     if ([annotation.layer isKindOfClass:[RMMarker class]] && ! annotation.isUserLocationAnnotation)
                         annotation.layer.transform = _annotationTransform;
             }
                             completion:nil];
            
            [CATransaction commit];
            
            self.userLocation.layer.hidden = NO;
            
            break;
        }
        case RMUserTrackingModeFollowWithHeading:
        {
            self.showsUserLocation = YES;
            
            self.userLocation.layer.hidden = YES;
            
            _userHaloTrackingView = [[NSImageView alloc] initWithImage:[RMMapView resourceImageNamed:@"TrackingDotHalo.png"]];
            
            _userHaloTrackingView.center = CGPointMake(round([self bounds].size.width  / 2),
                                                       round([self bounds].size.height / 2));
            
            _userHaloTrackingView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin  |
            UIViewAutoresizingFlexibleRightMargin |
            UIViewAutoresizingFlexibleTopMargin   |
            UIViewAutoresizingFlexibleBottomMargin;
            
            [self insertSubview:_userHaloTrackingView belowSubview:_overlayView];
            
            _userHeadingTrackingView = [[NSImageView alloc] initWithImage:[RMMapView resourceImageNamed:@"HeadingAngleLarge.png"]];
            
            _userHeadingTrackingView.frame = CGRectMake((self.bounds.size.width  / 2) - (_userHeadingTrackingView.bounds.size.width / 2),
                                                        (self.bounds.size.height / 2) - _userHeadingTrackingView.bounds.size.height,
                                                        _userHeadingTrackingView.bounds.size.width,
                                                        _userHeadingTrackingView.bounds.size.height * 2);
            
            _userHeadingTrackingView.contentMode = UIViewContentModeTop;
            
            _userHeadingTrackingView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin  |
            UIViewAutoresizingFlexibleRightMargin |
            UIViewAutoresizingFlexibleTopMargin   |
            UIViewAutoresizingFlexibleBottomMargin;
            
            _userHeadingTrackingView.alpha = 0.0;
            
            [self insertSubview:_userHeadingTrackingView belowSubview:_overlayView];
            
            _userLocationTrackingView = [[NSImageView alloc] initWithImage:[NSImage imageWithCGImage:(CGImageRef)self.userLocation.layer.contents
                                                                                               scale:self.userLocation.layer.contentsScale
                                                                                         orientation:NSImageOrientationUp]];
            
            _userLocationTrackingView.center = CGPointMake(round([self bounds].size.width  / 2),
                                                           round([self bounds].size.height / 2));
            
            _userLocationTrackingView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin  |
            UIViewAutoresizingFlexibleRightMargin |
            UIViewAutoresizingFlexibleTopMargin   |
            UIViewAutoresizingFlexibleBottomMargin;
            
            [self insertSubview:_userLocationTrackingView aboveSubview:_userHeadingTrackingView];
            
            if (self.zoom < 3)
                [self zoomByFactor:exp2f(3 - [self zoom]) near:self.center animated:YES];
            
            if (self.userLocation)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                [self locationManager:_locationManager didUpdateToLocation:self.userLocation.location fromLocation:self.userLocation.location];
#pragma clang diagnostic pop
            
            [self updateHeadingForDeviceOrientation];
            
            [_locationManager startUpdatingHeading];
            
            break;
        }
    }
#endif
    if (delegateRespondsTo.didChangeUserTrackingMode)
        [_delegate mapView:self didChangeUserTrackingMode:_userTrackingMode animated:animated];
}

//TODO: check
#if 0
- (void)locationManager:(CLLocationManager *)manager didUpdateToLocation:(CLLocation *)newLocation fromLocation:(CLLocation *)oldLocation
{
    if ( ! _showsUserLocation || _mapScrollView.isDragging || ! newLocation || ! CLLocationCoordinate2DIsValid(newLocation.coordinate))
        return;
    
    if ([newLocation distanceFromLocation:oldLocation])
    {
        self.userLocation.location = newLocation;
        
        if (delegateRespondsTo.didUpdateUserLocation)
            [_delegate mapView:self didUpdateUserLocation:self.userLocation];
    }
    
    if (self.userTrackingMode != RMUserTrackingModeNone)
    {
        // center on user location unless we're already centered there (or very close)
        //
        CGPoint mapCenterPoint    = [self convertPoint:self.center fromView:self.superview];
        CGPoint userLocationPoint = [self mapPositionForAnnotation:self.userLocation];
        
        if (fabsf(userLocationPoint.x - mapCenterPoint.x) > 1.0 || fabsf(userLocationPoint.y - mapCenterPoint.y) > 1.0)
        {
            if (round(_zoom) >= 10)
            {
                // at sufficient detail, just re-center the map; don't zoom
                //
                [self setCenterCoordinate:self.userLocation.location.coordinate animated:YES];
            }
            else
            {
                // otherwise re-center and zoom in to near accuracy confidence
                //
                float delta = (newLocation.horizontalAccuracy / 110000) * 1.2; // approx. meter per degree latitude, plus some margin
                
                CLLocationCoordinate2D desiredSouthWest = CLLocationCoordinate2DMake(newLocation.coordinate.latitude  - delta,
                                                                                     newLocation.coordinate.longitude - delta);
                
                CLLocationCoordinate2D desiredNorthEast = CLLocationCoordinate2DMake(newLocation.coordinate.latitude  + delta,
                                                                                     newLocation.coordinate.longitude + delta);
                
                CGFloat pixelRadius = fminf(self.bounds.size.width, self.bounds.size.height) / 2;
                
                CLLocationCoordinate2D actualSouthWest = [self pixelToCoordinate:CGPointMake(userLocationPoint.x - pixelRadius, userLocationPoint.y - pixelRadius)];
                CLLocationCoordinate2D actualNorthEast = [self pixelToCoordinate:CGPointMake(userLocationPoint.x + pixelRadius, userLocationPoint.y + pixelRadius)];
                
                if (desiredNorthEast.latitude  != actualNorthEast.latitude  ||
                    desiredNorthEast.longitude != actualNorthEast.longitude ||
                    desiredSouthWest.latitude  != actualSouthWest.latitude  ||
                    desiredSouthWest.longitude != actualSouthWest.longitude)
                {
                    [self zoomWithLatitudeLongitudeBoundsSouthWest:desiredSouthWest northEast:desiredNorthEast animated:YES];
                }
            }
        }
    }
    
    if ( ! _accuracyCircleAnnotation)
    {
        _accuracyCircleAnnotation = [RMAnnotation annotationWithMapView:self coordinate:newLocation.coordinate andTitle:nil];
        _accuracyCircleAnnotation.annotationType = kRMAccuracyCircleAnnotationTypeName;
        _accuracyCircleAnnotation.clusteringEnabled = NO;
        _accuracyCircleAnnotation.enabled = NO;
        _accuracyCircleAnnotation.layer = [[RMCircle alloc] initWithView:self radiusInMeters:newLocation.horizontalAccuracy];
        _accuracyCircleAnnotation.layer.zPosition = -MAXFLOAT;
        _accuracyCircleAnnotation.isUserLocationAnnotation = YES;
        
        ((RMCircle *)_accuracyCircleAnnotation.layer).lineColor = [UIColor colorWithRed:0.378 green:0.552 blue:0.827 alpha:0.7];
        ((RMCircle *)_accuracyCircleAnnotation.layer).fillColor = [UIColor colorWithRed:0.378 green:0.552 blue:0.827 alpha:0.15];
        
        ((RMCircle *)_accuracyCircleAnnotation.layer).lineWidthInPixels = 2.0;
        
        [self addAnnotation:_accuracyCircleAnnotation];
    }
    
    if ( ! oldLocation)
    {
        // make accuracy circle bounce until we get our second update
        //
        [CATransaction begin];
        [CATransaction setAnimationDuration:0.75];
        [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
        
        CABasicAnimation *bounceAnimation = [CABasicAnimation animationWithKeyPath:@"transform"];
        bounceAnimation.repeatCount = MAXFLOAT;
        bounceAnimation.fromValue = [NSValue valueWithCATransform3D:CATransform3DMakeScale(1.2, 1.2, 1.0)];
        bounceAnimation.toValue   = [NSValue valueWithCATransform3D:CATransform3DMakeScale(0.8, 0.8, 1.0)];
        bounceAnimation.removedOnCompletion = NO;
        bounceAnimation.autoreverses = YES;
        
        [_accuracyCircleAnnotation.layer addAnimation:bounceAnimation forKey:@"animateScale"];
        
        [CATransaction commit];
    }
    else
    {
        [_accuracyCircleAnnotation.layer removeAnimationForKey:@"animateScale"];
    }
    
    if ([newLocation distanceFromLocation:oldLocation])
        _accuracyCircleAnnotation.coordinate = newLocation.coordinate;
    
    if (newLocation.horizontalAccuracy != oldLocation.horizontalAccuracy)
        ((RMCircle *)_accuracyCircleAnnotation.layer).radiusInMeters = newLocation.horizontalAccuracy;
    
    if ( ! _trackingHaloAnnotation)
    {
        _trackingHaloAnnotation = [RMAnnotation annotationWithMapView:self coordinate:newLocation.coordinate andTitle:nil];
        _trackingHaloAnnotation.annotationType = kRMTrackingHaloAnnotationTypeName;
        _trackingHaloAnnotation.clusteringEnabled = NO;
        _trackingHaloAnnotation.enabled = NO;
        
        // create image marker
        //
        _trackingHaloAnnotation.layer = [[RMMarker alloc] initWithNSImage:[RMMapView resourceImageNamed:@"TrackingDotHalo.png"]];
        _trackingHaloAnnotation.layer.zPosition = -MAXFLOAT + 1;
        _trackingHaloAnnotation.isUserLocationAnnotation = YES;
        
        [CATransaction begin];
        [CATransaction setAnimationDuration:2.5];
        [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
        
        // scale out radially
        //
        CABasicAnimation *boundsAnimation = [CABasicAnimation animationWithKeyPath:@"transform"];
        boundsAnimation.repeatCount = MAXFLOAT;
        boundsAnimation.fromValue = [NSValue valueWithCATransform3D:CATransform3DMakeScale(0.1, 0.1, 1.0)];
        boundsAnimation.toValue   = [NSValue valueWithCATransform3D:CATransform3DMakeScale(2.0, 2.0, 1.0)];
        boundsAnimation.removedOnCompletion = NO;
        
        [_trackingHaloAnnotation.layer addAnimation:boundsAnimation forKey:@"animateScale"];
        
        // go transparent as scaled out
        //
        CABasicAnimation *opacityAnimation = [CABasicAnimation animationWithKeyPath:@"opacity"];
        opacityAnimation.repeatCount = MAXFLOAT;
        opacityAnimation.fromValue = [NSNumber numberWithFloat:1.0];
        opacityAnimation.toValue   = [NSNumber numberWithFloat:-1.0];
        opacityAnimation.removedOnCompletion = NO;
        
        [_trackingHaloAnnotation.layer addAnimation:opacityAnimation forKey:@"animateOpacity"];
        
        [CATransaction commit];
        
        [self addAnnotation:_trackingHaloAnnotation];
    }
    
    if ([newLocation distanceFromLocation:oldLocation])
        _trackingHaloAnnotation.coordinate = newLocation.coordinate;
    
    self.userLocation.layer.hidden = ( ! CLLocationCoordinate2DIsValid(self.userLocation.coordinate) || self.userTrackingMode == RMUserTrackingModeFollowWithHeading);
    
    if (_userLocationTrackingView)
        _userLocationTrackingView.hidden = ! CLLocationCoordinate2DIsValid(self.userLocation.coordinate);
    
    _accuracyCircleAnnotation.layer.hidden = newLocation.horizontalAccuracy <= 10 || self.userLocation.hasCustomLayer;
    
    _trackingHaloAnnotation.layer.hidden = ( ! CLLocationCoordinate2DIsValid(self.userLocation.coordinate) || newLocation.horizontalAccuracy > 10 || self.userTrackingMode == RMUserTrackingModeFollowWithHeading || self.userLocation.hasCustomLayer);
    
    if (_userHaloTrackingView)
    {
        _userHaloTrackingView.hidden = ( ! CLLocationCoordinate2DIsValid(self.userLocation.coordinate) || newLocation.horizontalAccuracy > 10 || self.userLocation.hasCustomLayer);
        
        // ensure animations are copied from layer
        //
        if ( ! [_userHaloTrackingView.layer.animationKeys count])
            for (NSString *animationKey in _trackingHaloAnnotation.layer.animationKeys)
                [_userHaloTrackingView.layer addAnimation:[[_trackingHaloAnnotation.layer animationForKey:animationKey] copy] forKey:animationKey];
    }
    
    if ( ! [_annotations containsObject:self.userLocation])
        [self addAnnotation:self.userLocation];
}

- (BOOL)locationManagerShouldDisplayHeadingCalibration:(CLLocationManager *)manager
{
    if (self.displayHeadingCalibration)
        [_locationManager performSelector:@selector(dismissHeadingCalibrationDisplay) withObject:nil afterDelay:10.0];
    
    return self.displayHeadingCalibration;
}

- (void)locationManager:(CLLocationManager *)manager didUpdateHeading:(CLHeading *)newHeading
{
    if ( ! _showsUserLocation || _mapScrollView.isDragging || newHeading.headingAccuracy < 0)
        return;
    
    if (newHeading.headingAccuracy > 40)
        _userHeadingTrackingView.image = [RMMapView resourceImageNamed:@"HeadingAngleLarge.png"];
    else if (newHeading.headingAccuracy >= 25 && newHeading.headingAccuracy <= 40)
        _userHeadingTrackingView.image = [RMMapView resourceImageNamed:@"HeadingAngleMedium.png"];
    else
        _userHeadingTrackingView.image = [RMMapView resourceImageNamed:@"HeadingAngleSmall.png"];
    
    self.userLocation.heading = newHeading;
    
    if (delegateRespondsTo.didUpdateUserLocation)
        [_delegate mapView:self didUpdateUserLocation:self.userLocation];
    
    if (newHeading.trueHeading != 0 && self.userTrackingMode == RMUserTrackingModeFollowWithHeading)
    {
        if (_userHeadingTrackingView.alpha < 1.0)
            [UIView animateWithDuration:0.5 animations:^(void) { _userHeadingTrackingView.alpha = 1.0; }];
        
        [CATransaction begin];
        [CATransaction setAnimationDuration:0.5];
        [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
        
        [UIView animateWithDuration:0.5
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationCurveEaseInOut
                         animations:^(void)
         {
             CGFloat angle = (M_PI / -180) * newHeading.trueHeading;
             
             _mapTransform = CGAffineTransformMakeRotation(angle);
             _annotationTransform = CATransform3DMakeAffineTransform(CGAffineTransformMakeRotation(-angle));
             
             _mapScrollView.transform = _mapTransform;
             _overlayView.transform   = _mapTransform;
             
             for (RMAnnotation *annotation in _annotations)
                 if ([annotation.layer isKindOfClass:[RMMarker class]] && ! annotation.isUserLocationAnnotation)
                     annotation.layer.transform = _annotationTransform;
             
             [self correctPositionOfAllAnnotations];
         }
                         completion:nil];
        
        [CATransaction commit];
    }
}

- (void)locationManager:(CLLocationManager *)manager didChangeAuthorizationStatus:(CLAuthorizationStatus)status
{
    if (status == kCLAuthorizationStatusDenied || status == kCLAuthorizationStatusRestricted)
    {
        self.userTrackingMode  = RMUserTrackingModeNone;
        self.showsUserLocation = NO;
    }
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error
{
    if ([error code] == kCLErrorDenied)
    {
        self.userTrackingMode  = RMUserTrackingModeNone;
        self.showsUserLocation = NO;
        
        if (delegateRespondsTo.didFailToLocateUserWithError)
            [_delegate mapView:self didFailToLocateUserWithError:error];
    }
}

- (void)updateHeadingForDeviceOrientation
{
    if (_locationManager)
    {
        // note that right/left device and interface orientations are opposites (see UIApplication.h)
        //
        switch ([[UIApplication sharedApplication] statusBarOrientation])
        {
            case (UIInterfaceOrientationLandscapeLeft):
            {
                _locationManager.headingOrientation = CLDeviceOrientationLandscapeRight;
                break;
            }
            case (UIInterfaceOrientationLandscapeRight):
            {
                _locationManager.headingOrientation = CLDeviceOrientationLandscapeLeft;
                break;
            }
            case (UIInterfaceOrientationPortraitUpsideDown):
            {
                _locationManager.headingOrientation = CLDeviceOrientationPortraitUpsideDown;
                break;
            }
            case (UIInterfaceOrientationPortrait):
            default:
            {
                _locationManager.headingOrientation = CLDeviceOrientationPortrait;
                break;
            }
        }
    }
}
#endif

#pragma mark -
#pragma mark Attribution

- (void)setHideAttribution:(BOOL)flag
{
    if (_hideAttribution == flag)
        return;
    
    _hideAttribution = flag;
    
    [self layoutSubviews];
}

- (NSViewController *)viewControllerPresentingAttribution
{
    return _viewControllerPresentingAttribution;
}

- (void)setViewControllerPresentingAttribution:(NSViewController *)viewController
{
    _viewControllerPresentingAttribution = viewController;
    
    if (_viewControllerPresentingAttribution && ! _attributionButton)
    {
//        _attributionButton = [UIButton buttonWithType:UIButtonTypeInfoLight];
        
//        _attributionButton.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleLeftMargin;
        
//        [_attributionButton addTarget:self action:@selector(showAttribution:) forControlEvents:UIControlEventTouchUpInside];
        
        _attributionButton.frame = CGRectMake(self.bounds.size.width  - 30,
                                              self.bounds.size.height - 30,
                                              _attributionButton.bounds.size.width,
                                              _attributionButton.bounds.size.height);
        
        [self addSubview:_attributionButton];
    }
    else if ( ! _viewControllerPresentingAttribution && _attributionButton)
    {
        [_attributionButton removeFromSuperview];
    }
}

- (void)showAttribution:(id)sender
{
    if (_viewControllerPresentingAttribution)
    {
        RMAttributionViewController *attributionViewController = [[RMAttributionViewController alloc] initWithMapView:self];
        
//        attributionViewController.modalTransitionStyle = UIModalTransitionStylePartialCurl;
        
//        [_viewControllerPresentingAttribution presentViewController:attributionViewController animated:YES completion:nil];
    }
}

- (void)test
{
    NSPoint center = {512, 512};
    [DuxScrollViewAnimation animatedScrollPointToCenter:center inScrollView:_mapScrollView];
}

@end
