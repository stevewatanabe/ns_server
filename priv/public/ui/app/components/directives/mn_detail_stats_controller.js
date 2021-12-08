/*
Copyright 2019-Present Couchbase, Inc.

Use of this software is governed by the Business Source License included in
the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
file, in accordance with the Business Source License, use of this software will
be governed by the Apache License, Version 2.0, included in the file
licenses/APL2.txt.
*/

import angular from 'angular';

import mnStatisticsNewService from '../../mn_admin/mn_statistics_service.js';
import mnStatisticsDescriptionService from '../../mn_admin/mn_statistics_description_service.js';
import mnStatisticsChart from '../../mn_admin/mn_statistics_chart_directive.js';
import mnHelper from '../mn_helper.js';
import mnPoolDefault from '../mn_pool_default.js';
import mnPermissions from '../mn_permissions.js';

export default 'mnDetailStatsModule';

angular
  .module('mnDetailStatsModule', [
    mnStatisticsNewService,
    mnStatisticsDescriptionService,
    mnStatisticsChart,
    mnHelper,
    mnPoolDefault,
    mnPermissions
  ])
  .component('mnDetailStats', {
    bindings: {
      mnTitle: "@",
      bucket: "@",
      itemId: "@",
      service: "@",
      prefix: "@",
      nodeName: "@?"
    },
    template: "<ng-include src=\"'/ui/app/components/directives/mn_detail_stats.html'\"></ng-include>",
    controller: ["mnStatisticsNewService", "mnStatisticsDescriptionService", "mnHelper", "$scope", "mnPoolDefault", "mnPermissions", controller]
  });

function controller(mnStatisticsNewService, mnStatisticsDescriptionService, mnHelper, $scope, mnPoolDefault, mnPermissions) {
  var vm = this;

  vm.zoom = "minute";
  vm.onSelectZoom = onSelectZoom;
  vm.items = {};
  vm.$onInit = activate;

  function onSelectZoom(selectedOption) {
    activate(selectedOption);
  }

  function getStats(stat) {
    var rv = {};
    rv["@" + vm.service + "-.@items." + stat] = true;
    return rv;
  }

  function activate(selectedZoom) {
    let permissions = mnPermissions.export.cluster.collection[(vm.bucket || ".") + ':.:.'];
    vm.isComponentDisabled = !(permissions && permissions.stats.read);

    if (vm.isComponentDisabled) {
      return;
    }

    selectedZoom = selectedZoom || vm.zoom;
    vm.scope = $scope;
    vm.mnAdminStatsPoller = mnStatisticsNewService.mnAdminStatsPoller;
    vm.mnAdminStatsPoller.heartbeat
      .setInterval(mnStatisticsNewService.defaultZoomInterval(selectedZoom));
    vm.items[vm.service] =
      mnPoolDefault.export.compat.atLeast70 ? vm.itemId : (vm.prefix + "/" + vm.itemId + "/");
    var stats = mnStatisticsDescriptionService.getStats();
    vm.charts = Object
      .keys(stats["@" + vm.service + "-"]["@items"])
      .filter(function (key) {
        return stats["@" + vm.service + "-"]["@items"][key];
      })
      .map(function (stat) {
        return {
          node: vm.nodeName,
          preset: true,
          id: mnHelper.generateID(),
          isSpecific: false,
          size: "small",
          stats: getStats(stat)
        };
      });
  }
}
