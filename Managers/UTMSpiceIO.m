//
// Copyright © 2020 osy. All rights reserved.
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
//

#import "UTMSpiceIO.h"
#import "UTMConfiguration.h"
#import "UTMConfiguration+Miscellaneous.h"
#import "UTMConfiguration+Sharing.h"
#import "UTMLogging.h"
#import "UTMViewState.h"
#import "CocoaSpice.h"

const int kMaxConnectionTries = 10; // qemu needs to start spice server first

@interface UTMSpiceIO ()

@property (nonatomic, nullable) CSConnection *spiceConnection;
@property (nonatomic, nullable) CSMain *spice;
@property (nonatomic, nullable) CSSession *session;
@property (nonatomic, nullable, copy) NSURL *sharedDirectory;
@property (nonatomic) NSInteger port;

@end

@implementation UTMSpiceIO {
    void (^_connectionBlock)(BOOL, NSError*);
}

- (instancetype)initWithConfiguration:(UTMConfiguration *)configuration port:(NSInteger)port {
    if (self = [super init]) {
        _configuration = configuration;
        _port = port;
    }
    
    return self;
}

- (void)setDelegate:(id<UTMSpiceIODelegate>)delegate {
    _delegate = delegate;
    _delegate.vmDisplay = self.primaryDisplay;
    _delegate.vmInput = self.primaryInput;
}

- (void)initializeSpiceIfNeeded {
    if (!self.spice) {
        self.spice = [[CSMain alloc] init];
    }
    
    if (!self.spiceConnection) {
        self.spiceConnection = [[CSConnection alloc] initWithHost:@"127.0.0.1" port:[NSString stringWithFormat:@"%lu", self.port]];
        self.spiceConnection.delegate = self;
        self.spiceConnection.audioEnabled = _configuration.soundEnabled;
    }
    
    self.spiceConnection.glibMainContext = self.spice.glibMainContext;
    [self.spice spiceSetDebug:YES];
    _primaryDisplay = nil;
    _primaryInput = nil;
    _delegate.vmDisplay = nil;
    _delegate.vmInput = nil;
}

- (BOOL)isSpiceInitialized {
    return self.spice != nil && self.spiceConnection != nil;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    // make sure the CSDisplay properties are synced with the CSInput
    if ([keyPath isEqualToString:@"primaryDisplay.viewportScale"]) {
        self.primaryInput.viewportScale = self.primaryDisplay.viewportScale;
    } else if ([keyPath isEqualToString:@"primaryDisplay.displaySize"]) {
        self.primaryInput.displaySize = self.primaryDisplay.displaySize;
    }
}

#pragma mark - UTMInputOutput

- (BOOL)startWithError:(NSError **)err {
    [self initializeSpiceIfNeeded];
    if (![self.spice spiceStart]) {
        // error
        return NO;
    }
    
    return YES;
}

- (void)connectWithCompletion: (void(^)(BOOL, NSError*)) block {
    int tries = kMaxConnectionTries;
    do {
        [NSThread sleepForTimeInterval:0.1f];
        if ([self.spiceConnection connect]) {
            break;
        }
    } while (tries-- > 0);
    if (tries == 0) {
        //TODO: error
        block(NO, nil);
    } else {
        _connectionBlock = block;
    }
}

- (void)disconnect {
    [self removeObserver:self forKeyPath:@"primaryDisplay.viewportScale"];
    [self removeObserver:self forKeyPath:@"primaryDisplay.displaySize"];
    [self.spiceConnection disconnect];
    self.spiceConnection.delegate = nil;
    self.spiceConnection = nil;
    [self.spice spiceStop];
    self.spice = nil;
}

- (UTMScreenshot *)screenshot {
    return [self.primaryDisplay screenshot];
}

- (void)setDebugMode:(BOOL)debugMode {
    [self.spice spiceSetDebug: debugMode];
}

- (void)syncViewState:(UTMViewState *)viewState {
    viewState.displayOriginX = self.primaryDisplay.viewportOrigin.x;
    viewState.displayOriginY = self.primaryDisplay.viewportOrigin.y;
    viewState.displaySizeWidth = self.primaryDisplay.displaySize.width;
    viewState.displaySizeHeight = self.primaryDisplay.displaySize.height;
    viewState.displayScale = self.primaryDisplay.viewportScale;
}

- (void)restoreViewState:(UTMViewState *)viewState {
    self.primaryDisplay.viewportOrigin = CGPointMake(viewState.displayOriginX, viewState.displayOriginY);
    self.primaryDisplay.displaySize = CGSizeMake(viewState.displaySizeWidth, viewState.displaySizeHeight);
    self.primaryDisplay.viewportScale = viewState.displayScale;
}

#pragma mark - CSConnectionDelegate

- (void)spiceConnected:(CSConnection *)connection {
    NSAssert(connection == self.spiceConnection, @"Unknown connection");
}

- (void)spiceDisconnected:(CSConnection *)connection {
    NSAssert(connection == self.spiceConnection, @"Unknown connection");
}

- (void)spiceError:(CSConnection *)connection err:(NSString *)msg {
    NSAssert(connection == self.spiceConnection, @"Unknown connection");
    //[self errorTriggered:msg];
    if (_connectionBlock) {
        _connectionBlock(NO, nil);
        _connectionBlock = nil;
    }
}

- (void)spiceDisplayCreated:(CSConnection *)connection display:(CSDisplayMetal *)display input:(CSInput *)input {
    NSAssert(connection == self.spiceConnection, @"Unknown connection");
    if (display.channelID == 0 && display.monitorID == 0) {
        _primaryDisplay = display;
        _primaryInput = input;
        _delegate.vmDisplay = display;
        _delegate.vmInput = input;
        [self addObserver:self forKeyPath:@"primaryDisplay.viewportScale" options:0 context:nil];
        [self addObserver:self forKeyPath:@"primaryDisplay.displaySize" options:0 context:nil];
        if (_connectionBlock) {
            _connectionBlock(YES, nil);
            _connectionBlock = nil;
        }
    }
}

- (void)spiceSessionCreated:(CSConnection *)connection session:(CSSession *)session {
    self.session = session;
    session.shareClipboard = self.configuration.shareClipboardEnabled;
    if (self.configuration.shareDirectoryEnabled) {
        [self startSharingDirectory];
    } else {
        UTMLog(@"shared directory disabled");
    }
}

- (void)spiceSessionEnded:(CSConnection *)connection session:(CSSession *)session {
    [self endSharingDirectory];
    self.session = nil;
}

#pragma mark - Shared Directory

- (void)changeSharedDirectory:(NSURL *)url {
    if (self.sharedDirectory) {
        [self endSharingDirectory];
    }
    self.sharedDirectory = url;
    if (self.session) {
        [self startSharingDirectory];
    }
}

- (void)startSharingDirectory {
    if (self.sharedDirectory) {
        UTMLog(@"setting share directory to %@", self.sharedDirectory.path);
        [self.session setSharedDirectory:self.sharedDirectory.path readOnly:self.configuration.shareDirectoryReadOnly];
    }
}

- (void)endSharingDirectory {
    if (self.sharedDirectory) {
        self.sharedDirectory = nil;
        UTMLog(@"ended share directory sharing");
    }
}

@end
