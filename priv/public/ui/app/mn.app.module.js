/*
Copyright 2020-Present Couchbase, Inc.

Use of this software is governed by the Business Source License included in
the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
file, in accordance with the Business Source License, use of this software will
be governed by the Apache License, Version 2.0, included in the file
licenses/APL2.txt.
*/

// app import should go first in order to load AngularJS before
// @angular/upgrade/static
import app from './app.js';

import {NgModule, ErrorHandler} from '@angular/core';
import {HTTP_INTERCEPTORS} from '@angular/common/http';
import {UpgradeModule} from '@angular/upgrade/static';
import {NgbModalConfig} from '@ng-bootstrap/ng-bootstrap';

import {ajsUpgradedProviders} from './ajs.upgraded.providers.js';
import {MnAppService} from './mn.app.service.js';
import {MnHelperService} from './mn.helper.service.js';
import {MnTasksService} from './mn.tasks.service.js';
import {MnSecurityService} from './mn.security.service.js';
import {MnServerGroupsService} from './mn.server.groups.service.js';
import {mnAppImports} from './mn.app.imports.js';
import {MnFormService} from './mn.form.service.js';
import {MnHttpInterceptor} from './mn.http.interceptor.js';
import {MnExceptionHandlerService} from './mn.exception.handler.service.js';

export {MnAppModule};

class MnAppModule {
  static get annotations() { return [
    new NgModule({
      declarations: [

      ],
      entryComponents: [

      ],
      imports: mnAppImports,
      // bootstrap: [
      //   UIView
      // ],
      providers: [
        ...ajsUpgradedProviders,
        MnSecurityService,
        MnServerGroupsService,
        MnAppService,
        MnTasksService,
        MnFormService,
        MnHelperService,
        {
          provide: HTTP_INTERCEPTORS,
          useClass: MnHttpInterceptor,
          multi: true
        }, {
          provide: ErrorHandler,
          useClass: MnExceptionHandlerService
        },
        NgbModalConfig
      ]
    })
  ]}

  static get parameters() {return  [
    UpgradeModule,
    NgbModalConfig
  ]}

  ngDoBootstrap() {
    this.upgrade.bootstrap(document, [app], { strictDi: false });
  }

  constructor(upgrade, ngbModalConfig) {
    this.upgrade = upgrade;
    ngbModalConfig.backdrop = "static";
  }

}
