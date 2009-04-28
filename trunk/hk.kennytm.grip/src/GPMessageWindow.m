/*

GPMessageWindow.m ... Message Window for typical GriP styles.
 
Copyright (c) 2009, KennyTM~
All rights reserved.
 
Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:
 
 * Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright notice, 
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
 * Neither the name of the KennyTM~ nor the names of its contributors may be
   used to endorse or promote products derived from this software without
   specific prior written permission.
 
THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 
*/

#import <objc/runtime.h>
#import <GriP/GPPreferences.h>
#import <GriP/GPMessageWindow.h>
#import <GriP/Duplex/Client.h>
#import <GriP/common.h>

#if GRIP_JAILBROKEN
__attribute__((visibility("hidden")))
@interface SBStatusBarController : NSObject
+(SBStatusBarController*)sharedStatusBarController;
-(UIWindow*)statusBarWindow;
@end

__attribute__((visibility("hidden")))
@interface SpringBoard : UIApplication
-(int)UIOrientation;
@end
#endif

static NSMutableArray* occupiedGaps = nil;
static NSMutableSet* unreleasedMessageWindows = nil;
#if GRIP_JAILBROKEN
static Class $SBStatusBarController = Nil;
#endif

static const int _oriented_locations_matrix[4][4] = {
{2, 0, 3, 1},  // -90 (status bar on the left)
{0, 1, 2, 3},  //   0 (normal)
{1, 3, 0, 2},  //  90 (status bar on the right)
{3, 2, 1, 0}}; // 180 (upside-down)

static const int _orientation_angles[4] = {0, 180, 90, -90};

@implementation GPMessageWindow
@synthesize pid, context, view;

+(void)_initialize {
	occupiedGaps = [[NSMutableArray alloc] init];
	unreleasedMessageWindows = [[NSMutableSet alloc] init];
#if GRIP_JAILBROKEN
	$SBStatusBarController = objc_getClass("SBStatusBarController");
#endif
}
+(void)_cleanup {
	[occupiedGaps release];
	[unreleasedMessageWindows release];
}

+(void)_removeGap:(GPGap)gap {
	[occupiedGaps removeObject:[NSValue valueWithBytes:&gap objCType:@encode(GPGap)]];
}
+(GPGap)_createGapWithHeight:(CGFloat)height {
	GPGap potentialGap;
	potentialGap.y = 0;
	potentialGap.h = height;
	
	// search a suitable location to display the window...
	NSUInteger gapIndex = 0;
	for (NSValue* v in occupiedGaps) {
		GPGap occupiedGap;
		[v getValue:&occupiedGap];
		if (occupiedGap.y >= potentialGap.y + potentialGap.h)
			break;
		else {
			potentialGap.y = occupiedGap.y + occupiedGap.h;
			++ gapIndex;
		}
	}
	
	[occupiedGaps insertObject:[NSValue valueWithBytes:&potentialGap objCType:@encode(GPGap)] atIndex:gapIndex];
	return potentialGap;
}
-(void)_releaseMyself {
	[self release];
	if (hiding) {
		self.hidden = YES;
		[view removeFromSuperview];
		[GPMessageWindow _removeGap:currentGap];
		[unreleasedMessageWindows removeObject:self];
	}
}

-(void)_layoutWithAnimation:(BOOL)animate {
	CGSize viewSize = view.frame.size;
	[GPMessageWindow _removeGap:currentGap];
	currentGap = [GPMessageWindow _createGapWithHeight:viewSize.height];
	
	// create frame of window.
	CGRect estimatedFrame = CGRectMake(0, currentGap.y, viewSize.width, viewSize.height);
	
	// obtain the current screen size & subtract the status bar from the screen.
	// (can't use [UIScreen mainScreen].applicationFrame because that returns
	//  SpringBoard's application frame and that's clearly not what we want.)
#if GRIP_JAILBROKEN
	CGRect currentScreenFrame = [UIScreen mainScreen].bounds;
	UIWindow* statusBar = [[$SBStatusBarController sharedStatusBarController] statusBarWindow];
	if (statusBar != nil) {
		CGRect statusFrame = statusBar.frame;
		NSLog(NSStringFromCGRect(statusFrame));
		if (statusFrame.size.width == currentScreenFrame.size.width) {
			if (statusFrame.origin.y == 0)
				currentScreenFrame.origin.y = statusFrame.size.height;
			currentScreenFrame.size.height -= statusFrame.size.height;
		} else {
			if (statusFrame.origin.x == 0)
				currentScreenFrame.origin.x = statusFrame.size.width;
			currentScreenFrame.size.width -= statusFrame.size.width;
		}
	}
#else
	CGRect currentScreenFrame = [UIScreen mainScreen].applicationFrame;	
#endif	
	
	UIApplication* app = [UIApplication sharedApplication];
	int uiOrientation;
#if GRIP_JAILBROKEN
	if ([app respondsToSelector:@selector(UIOrientation)])
		uiOrientation = [(SpringBoard*)app UIOrientation];
	else
#endif
		uiOrientation = _orientation_angles[app.statusBarOrientation-1];
	
	NSInteger location = [[GPPreferences() objectForKey:@"Location"] integerValue];
	
	// switch estimation box orientation if necessary.
	if (uiOrientation == 90 || uiOrientation == -90) {
		estimatedFrame = CGRectMake(estimatedFrame.origin.y, estimatedFrame.origin.x, estimatedFrame.size.height, estimatedFrame.size.width);
		// currentScreenFrame = CGRectMake(currentScreenFrame.origin.y, currentScreenFrame.origin.x, currentScreenFrame.size.height, currentScreenFrame.size.width);
	}
	
	NSInteger adjustedLocation = _oriented_locations_matrix[uiOrientation/90+1][location];
		
	// flip horizontal alignment if on the right.
	if (adjustedLocation & 1)
		estimatedFrame.origin.x = currentScreenFrame.size.width - estimatedFrame.size.width - estimatedFrame.origin.x;
	
	// flip vertical position if at the bottom.
	if (adjustedLocation & 2)
		estimatedFrame.origin.y = currentScreenFrame.size.height - estimatedFrame.size.height - estimatedFrame.origin.y;
	
	estimatedFrame.origin.x += currentScreenFrame.origin.x;
	estimatedFrame.origin.y += currentScreenFrame.origin.y;
		
	// change frame smoothly, if required.
	// frankly speaking... I don't know what I'm doing here.
	self.frame = estimatedFrame;
	UIView* transformerView = [self.subviews objectAtIndex:0];
	transformerView.bounds = CGRectMake(0, 0, viewSize.width, viewSize.height);
	transformerView.center = CGPointMake(estimatedFrame.size.width/2, estimatedFrame.size.height/2);
	transformerView.transform = CGAffineTransformMakeRotation(uiOrientation*M_PI/180);
	view.frame = CGRectMake(0, 0, viewSize.width, viewSize.height);
	
	if (animate)
		[UIView commitAnimations];
	
	
	
}

+(GPMessageWindow*)registerWindowWithView:(UIView*)view_ message:(NSDictionary*)message {
	GPMessageWindow* window = [[self alloc] initWithView:view_ message:message];
	if (window != nil) {
		[unreleasedMessageWindows addObject:window];
		[window release];
	}
	return window;
}

-(id)initWithView:(UIView*)view_ message:(NSDictionary*)message {
	if ((self = [super init])) {
		UIView* transformerView = [[UIView alloc] init];
		[transformerView addSubview:view_];
		[self addSubview:transformerView];
		[transformerView release];
		view = view_;
		[self _layoutWithAnimation:NO];
		[self refreshWithMessage:message];
		self.windowLevel = UIWindowLevelStatusBar*2;
		self.hidden = NO;
		identitifer = [[message objectForKey:GRIP_ID] retain];
	}
	return self;
}

-(void)refreshWithMessage:(NSDictionary*)message {
	[self stopHiding];
	
	if (!forceSticky) {
		[self stopTimer];
		sticky = [[message objectForKey:GRIP_STICKY] boolValue];
		[self _startTimer];
	}
	
	[pid release];
	pid = [[message objectForKey:GRIP_PID] retain];
	
	[context release];
	context = [[message objectForKey:GRIP_CONTEXT] retain];
	
	isURL = [[message objectForKey:GRIP_ISURL] boolValue];
}

-(void)prepareForResizing {
	[UIView beginAnimations:@"GPMW-Move" context:NULL];
}
-(void)resize { [self _layoutWithAnimation:YES]; }

-(void)restartTimer {
	[self stopTimer];
	[self _startTimer];
}
-(void)_startTimer {
	if (!sticky)
		hideTimer = [[NSTimer scheduledTimerWithTimeInterval:[[GPPreferences() objectForKey:@"HideTimer"] floatValue] target:self selector:@selector(hide) userInfo:nil repeats:NO] retain];
}
-(void)stopTimer {
	if (!sticky) {
		[hideTimer invalidate];
		[hideTimer release];
		hideTimer = nil;
	}
}

-(void)stopHiding {
	hiding = NO;
	self.hidden = NO;
	self.alpha = 1;
}

-(void)hide { [self hide:YES]; }

-(void)hide:(BOOL)ignored {
	NSData* portAndContext = [NSPropertyListSerialization dataFromPropertyList:[NSArray arrayWithObjects:pid, context, [NSNumber numberWithBool:isURL], nil] format:NSPropertyListBinaryFormat_v1_0 errorDescription:NULL];
	[GPDuplexClient sendMessage:(ignored?GriPMessage_IgnoredNotification:GriPMessage_ClickedNotification) data:portAndContext];
	
	[self stopTimer];
	hiding = YES;
	[self retain];
	
	[UIView beginAnimations:@"GPMW-Hide" context:NULL];
	[UIView setAnimationDelegate:self];
	[UIView setAnimationDidStopSelector:@selector(_releaseMyself)];
	[UIView setAnimationDuration:0.5];
	self.alpha = 0;
	[UIView commitAnimations];
}

-(void)forceSticky {
	sticky = YES;
	forceSticky = YES;
	[self stopTimer];
}

-(void)dealloc {
	[self stopTimer];
	[pid release];
	[context release];
	[GPDuplexClient sendMessage:GriPMessage_DisposeIdentifier data:[identitifer dataUsingEncoding:NSUTF8StringEncoding]];
	[identitifer release];
	[super dealloc];
}

@end