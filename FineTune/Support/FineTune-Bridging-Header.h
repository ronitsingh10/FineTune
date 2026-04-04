#import <IOBluetooth/IOBluetooth.h>

@interface IOBluetoothDevice (FineTunePrivate)
@property (nonatomic, readonly) BOOL isANCSupported;
@property (nonatomic, readonly) BOOL isTransparencySupported;
@property (nonatomic) unsigned char listeningMode;
@end
