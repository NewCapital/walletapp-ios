//
//  StartFlowPresenter.swift
//  breadwallet
//
//  Created by Adrian Corscadden on 2016-10-22.
//  Copyright © 2016 breadwallet LLC. All rights reserved.
//

import UIKit

class StartFlowPresenter: Subscriber {

    init(walletManager: BTCWalletManager, 
         rootViewController: RootNavigationController, 
         createHomeScreen: @escaping (UINavigationController) -> HomeScreenViewController,
         createBuyScreen: @escaping () -> BRWebViewController) {
        self.walletManager = walletManager
        self.rootViewController = rootViewController
        self.navigationControllerDelegate = StartNavigationDelegate()
        self.createHomeScreen = createHomeScreen
        self.createBuyScreen = createBuyScreen
        addSubscriptions()
    }

    // MARK: - Private
    private let rootViewController: RootNavigationController
    private var navigationController: ModalNavigationController?
    private let navigationControllerDelegate: StartNavigationDelegate
    private let walletManager: BTCWalletManager
    private var loginViewController: UIViewController?
    private let loginTransitionDelegate = LoginTransitionDelegate()
    private var createHomeScreen: ((UINavigationController) -> HomeScreenViewController)?
    private var createBuyScreen: (() -> BRWebViewController)?
    private var shouldBuyCoinAfterOnboarding: Bool = false
    
    private var closeButton: UIButton {
        let button = UIButton.close
        button.tintColor = .white
        button.tap = {
            Store.perform(action: HideStartFlow())
        }
        return button
    }

    private func addSubscriptions() {
        Store.lazySubscribe(self,
                        selector: { $0.isStartFlowVisible != $1.isStartFlowVisible },
                        callback: { self.handleStartFlowChange(state: $0) })
        Store.lazySubscribe(self,
                        selector: { $0.isLoginRequired != $1.isLoginRequired },
                        callback: { self.handleLoginRequiredChange(state: $0)
        })
        Store.subscribe(self, name: .lock, callback: { _ in
            self.presentLoginFlow(isPresentedForLock: true)
        })
    }

    private func handleStartFlowChange(state: State) {
        if state.isStartFlowVisible {
            guardProtected(queue: DispatchQueue.main) { [weak self] in
                if Store.state.shouldShowOnboarding {
                    self?.presentOnboardingFlow() 
                } else {
                    self?.presentStartFlow()
                }
            }
        } else {
            dismissStartFlow()
        }
    }

    private func handleLoginRequiredChange(state: State) {
        if state.isLoginRequired {
            presentLoginFlow(isPresentedForLock: false)
        } else {
            dismissLoginFlow()
        }
    }

    private func enterRecoverWalletFlow() {
        let recoverIntro = RecoverWalletIntroViewController(didTapNext: self.pushRecoverWalletView)
        navigationController?.setClearNavbar()
        navigationController?.setNavigationBarHidden(false, animated: false)
        navigationController?.pushViewController(recoverIntro, animated: true)
    }

    // Displays the onboarding screen (app landing page) that allows the user to either create
    // a new wallet or restore an existing wallet. 
    private func presentOnboardingFlow() {
        let onboardingScreen = OnboardingViewController(didExitOnboarding: { [weak self] (action) in
            guard let `self` = self else { return }
            
            switch action {
            case .restoreWallet:
                self.enterRecoverWalletFlow()
            case .createWallet:
                self.enterCreateWalletFlow()
            case .createWalletBuyCoin:
                // This will be checked in dismissStartFlow(), which is called after the PIN
                // and paper key flows are finished.
                self.shouldBuyCoinAfterOnboarding = true
                self.enterCreateWalletFlow()
            }
        })
        
        navigationController = ModalNavigationController(rootViewController: onboardingScreen)
        navigationController?.delegate = navigationControllerDelegate

        if let onboardingFlow = navigationController {            
            onboardingFlow.setNavigationBarHidden(true, animated: false)
            
            // This will be set to true if the user exits onboarding with the `createWalletBuyCoin` action.
            shouldBuyCoinAfterOnboarding = false
            
            rootViewController.present(onboardingFlow, animated: false, completion: {
                
                // Stuff the home screen in as the root view controller so that when
                // the onboarding flow is finished, the home screen will be present. If 
                // we push it before the present() call you can briefly see the home screen
                // before the onboarding screen is displayed -- not good.
                if let createHomeScreen = self.createHomeScreen {
                    let homeScreen = createHomeScreen(self.rootViewController)
                    self.rootViewController.pushViewController(homeScreen, animated: false)
                }                
            })
        }
    }
    
    private func presentStartFlow() {
        let startViewController = StartViewController(didTapCreate: enterCreateWalletFlow,
                                                      didTapRecover: enterRecoverWalletFlow)

        navigationController = ModalNavigationController(rootViewController: startViewController)
        navigationController?.delegate = navigationControllerDelegate
        if let startFlow = navigationController {
            rootViewController.popToRootViewController(animated: false)
            startFlow.setNavigationBarHidden(true, animated: false)
            rootViewController.present(startFlow, animated: false, completion: nil)
        }
    }

    private var pushRecoverWalletView: () -> Void {
        return { [weak self] in
            guard let myself = self else { return }
            let recoverWalletViewController =
                EnterPhraseViewController(walletManager: myself.walletManager,
                                          reason: .setSeed(myself.pushPinCreationViewForRecoveredWallet))
            myself.navigationController?.pushViewController(recoverWalletViewController, animated: true)
        }
    }

    private var pushPinCreationViewForRecoveredWallet: (String) -> Void {
        return { [weak self] phrase in
            guard let myself = self else { return }
            let pinCreationView = UpdatePinViewController(walletManager: myself.walletManager, type: .creationWithPhrase, showsBackButton: false, phrase: phrase)
            pinCreationView.setPinSuccess = { _ in
                DispatchQueue.main.async {
                    Store.trigger(name: .didCreateOrRecoverWallet)
                }
            }
            myself.navigationController?.pushViewController(pinCreationView, animated: true)
        }
    }

    private func presentPostOnboardingBuyScreen() {
        guard let createBuyScreen = createBuyScreen else { return }
        
        let buyScreen = createBuyScreen()
        
        buyScreen.didClose = { [unowned self] in
            self.navigationController = nil
        }
                
        self.navigationController?.pushViewController(buyScreen, animated: true)
    }
    
    private func dismissStartFlow() {
        if self.shouldBuyCoinAfterOnboarding {
            self.presentPostOnboardingBuyScreen()
        } else {
            navigationController?.dismiss(animated: true) { [unowned self] in
                self.navigationController = nil
            }
        }
    }

    private func enterCreateWalletFlow() {
        let pinCreationViewController = UpdatePinViewController(walletManager: walletManager, type: .creationNoPhrase, showsBackButton: true, phrase: nil)
        pinCreationViewController.setPinSuccess = { [weak self] pin in
            autoreleasepool {
                guard self?.walletManager.setRandomSeedPhrase() != nil else { self?.handleWalletCreationError(); return }
                //TODO:BCH multi-currency support
                UserDefaults.selectedCurrencyCode = nil // to land on home screen after new wallet creation
                Store.perform(action: WalletChange(Currencies.btc).setWalletCreationDate(Date()))
                DispatchQueue.main.async {
                    self?.pushStartPaperPhraseCreationViewController(pin: pin)
                    Store.trigger(name: .didCreateOrRecoverWallet)
                }
            }
        }

        navigationController?.setClearNavbar()
        navigationController?.setNavigationBarHidden(false, animated: false)
        navigationController?.pushViewController(pinCreationViewController, animated: true)
    }

    private func handleWalletCreationError() {
        let alert = UIAlertController(title: S.Alert.error, message: "Could not create wallet", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: S.Button.ok, style: .default, handler: nil))
        navigationController?.present(alert, animated: true, completion: nil)
    }
    
    private func pushStartPaperPhraseCreationViewController(pin: String) {
        let paperPhraseViewController = StartPaperPhraseViewController(callback: { [weak self] in
            self?.pushWritePaperPhraseViewController(pin: pin)
        })
        paperPhraseViewController.title = S.SecurityCenter.Cells.paperKeyTitle
        paperPhraseViewController.navigationItem.setHidesBackButton(true, animated: false)
        paperPhraseViewController.navigationItem.leftBarButtonItems = [UIBarButtonItem.negativePadding, UIBarButtonItem(customView: closeButton)]

        let faqButton = UIButton.buildFaqButton(articleId: ArticleIds.paperKey)
        faqButton.tintColor = .white
        paperPhraseViewController.navigationItem.rightBarButtonItems = [UIBarButtonItem.negativePadding, UIBarButtonItem(customView: faqButton)]

        navigationController?.navigationBar.titleTextAttributes = [
            NSAttributedStringKey.foregroundColor: UIColor.white,
            NSAttributedStringKey.font: UIFont.customBold(size: 17.0)
        ]
        navigationController?.pushViewController(paperPhraseViewController, animated: true)
    }

    private func pushWritePaperPhraseViewController(pin: String) {
        let writeViewController = WritePaperPhraseViewController(walletManager: walletManager, pin: pin, callback: { [weak self] in
            self?.pushConfirmPaperPhraseViewController(pin: pin)
        })
        writeViewController.title = S.SecurityCenter.Cells.paperKeyTitle
        writeViewController.navigationItem.leftBarButtonItems = [UIBarButtonItem.negativePadding, UIBarButtonItem(customView: closeButton)]
        navigationController?.pushViewController(writeViewController, animated: true)
    }

    private func pushConfirmPaperPhraseViewController(pin: String) {
        let confirmViewController = ConfirmPaperPhraseViewController(walletManager: walletManager, pin: pin, callback: {
            Store.perform(action: Alert.Show(.paperKeySet(callback: {
                Store.perform(action: HideStartFlow())
            })))
        })
        confirmViewController.title = S.SecurityCenter.Cells.paperKeyTitle
        navigationController?.navigationBar.tintColor = .white
        navigationController?.pushViewController(confirmViewController, animated: true)
    }

    private func presentLoginFlow(isPresentedForLock: Bool) {
        let loginView = LoginViewController(isPresentedForLock: isPresentedForLock, walletManager: walletManager)
        loginView.transitioningDelegate = loginTransitionDelegate
        loginView.modalPresentationStyle = .overFullScreen
        loginView.modalPresentationCapturesStatusBarAppearance = true
        loginViewController = loginView
        if let modal = rootViewController.presentedViewController {
            modal.dismiss(animated: false, completion: {
                self.rootViewController.present(loginView, animated: false, completion: nil)
            })
        } else {
            rootViewController.present(loginView, animated: false, completion: nil)
        }
    }

    private func dismissLoginFlow() {
        loginViewController?.dismiss(animated: true, completion: { [weak self] in
            self?.loginViewController = nil
        })
    }
}
