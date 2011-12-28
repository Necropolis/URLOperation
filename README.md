# FSURLOperation

Easily enqueue `NSURLRequest`s into an `NSOperationQueue`, set up dependencies, run on threads, and just overall bang out web traffic like a boss.

What does this get you that other tools don't? Not a whole lot! So why should you care?

- It's minimalist, and therefore very flexible.
- It's designed for the flexibility to function correctly in a heavily multi-threaded environment.

## FSURLOperation might be for you if you're thinking these thoughts:

- I have to make a lot of URL requests
- Other wrappers are too heavy and/or fail
- I like blocks
- I think blocks like me
- I hate not having direct and easy access to the `NSURLResponse` of a request
- I hate not having direct and easy access to the `NSData` of a request
- I want to have children with `NSOperationQueue`, but I don't know the right phone number to call and set up a date

## You've piqued my interest; show me an example!

Fine:

```
NSURLRequest* req =
  [NSURLRequest requestWithURL:[NSURL URLWithString:@"http://fsdev.net/"]];
NSData* mySite = nil;
FSURLOperation* oper =
  [FSURLOperation URLOperationWithRequest:req
                          completionBlock:^(NSHTTPURLResponse* resp,
                                            NSData* payload,
                                            NSError* asplosion) {
                            mySite = payload;
                          }];
NSBlockOperation* onFinish =
  [NSBlockOperation blockOperationWithBlock:^{
    NSMutableURLRequest* spamReq =
      [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://www.spam.com/"]];
    [spamReq setHTTPBody:mySite];
    FSURLOperation* spamOper =
      [FSURLOperation URLOperationWithRequest:req
                              completionBlock:^(NSHTTPURLResponse* resp,
                                                NSData* payload,
                                                NSError* aspolsion) {
                                NSLog(@"%@", [payload fs_stringValue]);
                              }];
    [[NSOperationQueue mainQueue] addOperation:spamOper];
  }];
[onFinish addDependency:oper];
[[NSOperationQueue mainQueue] addOperations:[NSArray arrayWithObjects:onFinish, oper, nil]
                              waitUntilDone:NO];
```

In layman's terms, "do this web request, then after that perform this code." I think it's pretty damn awesome, and so I'm sharing it with you. It's saved me a bucket load of not-lulz when dealing with web requests that begat web requests which begat web requests which begat a threadlock. I'll wager that it can save you some time, too.

Enjoy!
