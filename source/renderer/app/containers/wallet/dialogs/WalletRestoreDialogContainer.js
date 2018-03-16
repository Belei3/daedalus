// @flow
import React, { Component } from 'react';
import { observer, inject } from 'mobx-react';
import WalletRestoreDialog from '../../../components/wallet/WalletRestoreDialog';
import type { InjectedDialogContainerProps } from '../../../types/injectedPropsType';
import environment from '../../../../../common/environment';
import validWords from '../../../../../common/valid-words.en';

type Props = InjectedDialogContainerProps;

@inject('stores', 'actions') @observer
export default class WalletRestoreDialogContainer extends Component<Props> {

  static defaultProps = { actions: null, stores: null, children: null, onClose: () => {} };

  onSubmit = (values: {
    recoveryPhrase: string,
    walletName: string,
    walletPassword: ?string,
    type: string,
    certificatePassword?: string,
  }) => {
    this.props.actions[environment.API].wallets.restoreWallet.trigger(values);
  };

  onCancel = () => {
    this.props.onClose();
    // Restore request should be reset only in case restore is finished/errored
    const { restoreRequest } = this._getWalletsStore();
    if (!restoreRequest.isExecuting) restoreRequest.reset();
  };

  render() {
    const wallets = this._getWalletsStore();
    const { restoreRequest, isValidMnemonic, isValidCertificateMnemonic } = wallets;

    return (
      <WalletRestoreDialog
        mnemonicValidator={mnemonic => isValidMnemonic(mnemonic)}
        certificateMnemonicValidator={mnemonic => isValidCertificateMnemonic(mnemonic)}
        suggestedMnemonics={validWords}
        isSubmitting={restoreRequest.isExecuting}
        onSubmit={this.onSubmit}
        onCancel={this.onCancel}
        error={restoreRequest.error}
      />
    );
  }

  _getWalletsStore() {
    return this.props.stores[environment.API].wallets;
  }
}
