
#include "qmactouchbar.h"

#include <QtWidgets>
#import <AppKit/AppKit.h>

// An NSObject that tracks a QObject, like QPointer.
@interface QObjectPointer : NSObject
{
    QObject *_qobject;
    QMetaObject::Connection _destroyedConnection;
}
@property (readonly) QObject *qobject;
@end

@implementation QObjectPointer
@synthesize qobject = _qobject;

-(id)initWithQObject:(QObject *)aQObject
{
    self = [super init];
    _qobject = aQObject;

    // Connect to QObject detroyed in order to clear the stored QObject pointer
    // on its deletion. Capture a pointer to the QObject pointer instead of
    // caputuring self, which will create a circular reference. (Capturing __weak self
    // in a C++ lambda does not seem to work).
    auto qobjectPtr = &_qobject;
    _destroyedConnection = QObject::connect(_qobject, &QObject::destroyed, [qobjectPtr]()
    {
        qDebug() << "QObjectPointer clear QObject pointer";
        *qobjectPtr = nullptr;
    });

    return self;
}

-(void)dealloc
{
    [super dealloc];
    QObject::disconnect(_destroyedConnection);
}

@end

@interface DynamicTouchBarProvider : NSResponder <NSTouchBarDelegate, NSApplicationDelegate, NSWindowDelegate>
@property (strong) NSMutableDictionary *items;
@property (strong) NSMutableDictionary *order;
@property (strong) NSMutableDictionary *commands;
@property (strong) NSObject *qtDelegate;
@end

@implementation DynamicTouchBarProvider
@synthesize items;
@synthesize order;
@synthesize commands;

- (id)init {
    self = [super init];
    items = [NSMutableDictionary dictionary];
    order = [NSMutableDictionary dictionary];
    commands = [NSMutableDictionary dictionary];
    return self;
}

- (void)addItem:(Command *)command
{

    const QString title = command->touchBarTitle();
    if (title.isEmpty())
        return;

    // Create custom button item
    NSString *identifer = command->id().toNSString();

#if 0
    NSCustomTouchBarItem *item = [[[NSCustomTouchBarItem alloc] initWithIdentifier:identifer] autorelease];

    NSButton *button = [[NSButton buttonWithTitle:title.toNSString() target:self
                        action:@selector(itemAction:)] autorelease];
//    button.enabled = command->isActive();
    item.view = button;

    [item retain];
    [item.view retain];

    [items setObject:item forKey:identifer];
    [order setObject:[NSNumber numberWithInt:command->macTouchBarOrder()] forKey:identifer];
    [commands setObject:[[QObjectPointer alloc]initWithQObject:command] forKey:[NSValue valueWithPointer:button]];
#else
    if(command->controlType() == Command::Button)
    {
        NSCustomTouchBarItem *item = nil;
        item = [[[NSCustomTouchBarItem alloc] initWithIdentifier:identifer] autorelease];
        //
        NSButton *button = [[NSButton buttonWithTitle:title.toNSString() target:self
                            action:@selector(itemAction:)] autorelease];
        //
        // button.image = [NSImage imageNamed:NSImageNameTouchBarDownloadTemplate];
        button.title = title.toNSString();
        button.imagePosition =  NSImageLeft;
        //
        item.view = button;


        [item retain];
        [item.view retain];

        [items setObject:item forKey:identifer];
        [order setObject:[NSNumber numberWithInt:command->macTouchBarOrder()] forKey:identifer];
        [commands setObject:[[QObjectPointer alloc]initWithQObject:command] forKey:[NSValue valueWithPointer:button]];
    }
    else
    {
        NSTouchBarItem *item = nil;
        if(command->controlType() == Command::ColorPickerColor)
        {
            item = [NSColorPickerTouchBarItem colorPickerWithIdentifier:identifer];
        }
        else if(command->controlType() == Command::ColorPickerText)
        {
            item = [NSColorPickerTouchBarItem textColorPickerWithIdentifier:identifer];
        }
        else if(command->controlType() == Command::ColorPickerStroke)
        {
            item = [NSColorPickerTouchBarItem strokeColorPickerWithIdentifier:identifer];
        }
//        else if(command->controlType() == Command::CandidateList)
//        {
//            item = [NSCandidateListTouchBarItem strokeColorPickerWithIdentifier:identifer];
//        }
        else if(command->controlType() == Command::SharingService)
        {
            item = [[NSSharingServicePickerTouchBarItem alloc] initWithIdentifier:identifer];
        }
        //
        [item retain];
        [items setObject:item forKey:identifer];
        [order setObject:[NSNumber numberWithInt:command->macTouchBarOrder()] forKey:identifer];
    }
#endif
}

- (void)itemAction:(id)sender
{
    QObjectPointer *qobjectPointer = (QObjectPointer *)[commands objectForKey:[NSValue valueWithPointer:sender]];
    // Missing entry in commands dict. Should not really happen, but does
    if (!qobjectPointer)
        return;

    // Check for deleted QObject
    if (!qobjectPointer.qobject)
        return;

    Command *command = static_cast<Command *>(qobjectPointer.qobject);
    QAction *action = command->action();
    if (!action)
        return;
    if (!action->isEnabled())
        return;
    action->activate(QAction::Trigger);
}

- (void)clearItems
{
    [items removeAllObjects];
    [order removeAllObjects];
    [commands removeAllObjects];
}

- (NSTouchBar *)makeTouchBar
{
    // Create the touch bar with this instance as its delegate
    NSTouchBar *touchBar = [[NSTouchBar alloc] init];
    touchBar.delegate = self;

    // Add ordered items array
    touchBar.defaultItemIdentifiers = [order keysSortedByValueUsingComparator:^NSComparisonResult(id a, id b) {
        return [a compare:b];
    }];

//    [touchBar.defaultItemIdentifiers addObject:NSTouchBarItemIdentifierOtherItemsProxy];

    return touchBar;
}

- (NSTouchBarItem *)touchBar:(NSTouchBar *)touchBar makeItemForIdentifier:(NSTouchBarItemIdentifier)identifier
{
    Q_UNUSED(touchBar);

    if ([self.items objectForKey:identifier] != nil)
        return [self.items objectForKey:identifier];

    return nil;
}

- (void)installAsDelegateForWindow:(NSWindow *)window
{
    _qtDelegate = window.delegate; // Save current delegate for forwarding
    window.delegate = self;
}

- (void)installAsDelegateForApplication:(NSApplication *)application
{
    _qtDelegate = application.delegate; // Save current delegate for forwarding
    application.delegate = self;
}

- (BOOL)respondsToSelector:(SEL)aSelector
{
    // We want to forward to the qt delegate. Respond to selectors it
    // responds to in addition to selectors this instance resonds to.
    return [_qtDelegate respondsToSelector:aSelector] || [super respondsToSelector:aSelector];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation
{
    // Forward to the existing delegate. This function is only called for selectors
    // this instance does not responds to, which means that the qt delegate
    // must respond to it (due to the respondsToSelector implementation above).
    [anInvocation invokeWithTarget:_qtDelegate];
}

@end

static DynamicTouchBarProvider *touchBarProvider = nil;

Command::Command(QObject* parent,QString id, int order,
                 QString title, QAction *action, ControlType controlType)
    :QObject(parent)
{
    m_id = id;
    m_macTouchBarOrder = order;
    m_touchBarTitle = title;
    m_action = action;
    //
    m_controlType = controlType;
}

Command::~Command()
{

}

QString Command::id()
{
    return m_id;
}

QAction* Command::action()
{
    return m_action;
}

QString Command::touchBarTitle()
{
    return m_touchBarTitle;
}

int Command::macTouchBarOrder()
{
    return m_macTouchBarOrder;
}

Command::ControlType Command::controlType()
{
    return m_controlType;
}


QMacTouchBar::QMacTouchBar()
{
    // ### This is really a singleton class
    touchBarProvider = [[DynamicTouchBarProvider alloc] init];
    [touchBarProvider installAsDelegateForApplication:[NSApplication sharedApplication]];
}

QMacTouchBar::QMacTouchBar(QWidget* parent)
{
    // ### This is really a singleton class
    touchBarProvider = [[DynamicTouchBarProvider alloc] init];
    NSView *view = reinterpret_cast<NSView *>(parent->winId());
    [touchBarProvider installAsDelegateForWindow:view.window];
}


QMacTouchBar::~QMacTouchBar()
{
    [touchBarProvider release];
}

void QMacTouchBar::addItem(Command *command)
{
    [touchBarProvider addItem:command];
}

void QMacTouchBar::clear()
{
    [touchBarProvider clearItems];
    touchBarProvider.touchBar = nil;
}

