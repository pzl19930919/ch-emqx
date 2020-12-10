webpackJsonp([21],{Tk0c:function(e,t,r){"use strict";Object.defineProperty(t,"__esModule",{value:!0});var a=r("Dd8w"),s=r.n(a),o=r("zL8q"),i=r("CqLJ"),l=r.n(i),p={name:"applications-view",components:{"el-dialog":o.Dialog,"el-input":o.Input,"el-switch":o.Switch,"el-select":o.Select,"el-option":o.Option,"el-button":o.Button,"el-table":o.Table,"el-table-column":o.TableColumn,"el-date-picker":o.DatePicker,"el-popover":o.Popover,"el-tooltip":o.Tooltip,"el-form":o.Form,"el-form-item":o.FormItem,"el-row":o.Row,"el-col":o.Col},data:function(){return{tableData:[],displayDialog:!1,oper:"new",record:{app_id:"",name:"",desc:"",secret:"",expired:"",status:!0},rules:{app_id:[{required:!0,message:this.$t("app.errors")}],name:[{required:!0,message:this.$t("app.errors")}]},popoverVisible:!1,pickerDisable:{disabledDate:function(e){return e.getTime()<Date.now()-864e5}},lang:window.localStorage.getItem("language")||"en"}},methods:{loadData:function(){var e=this;this.$httpGet("/apps").then(function(t){e.tableData=t.data}).catch(function(t){e.$message.error(t||e.$t("error.networkError"))})},createApp:function(){var e=this;this.$refs.record.validate(function(t){if(t){var r=s()({},e.record);13===new Date(r.expired).getTime().toString().length?r.expired/=1e3:r.expired=void 0,e.$httpPost("/apps",r).then(function(){e.loadData(),e.$message.success(e.$t("success.createSuccess")),e.displayDialog=!1}).catch(function(t){e.$message.error(t||e.$t("error.networkError"))})}})},updateApp:function(){var e=this,t=arguments.length>0&&void 0!==arguments[0]&&arguments[0],r=arguments[1];if(t){var a=s()({},r);13===new Date(a.expired).getTime().toString().length?a.expired/=1e3:a.expired=void 0,this.$httpPut("/apps/"+a.app_id,a).then(function(){e.$message.success(e.$t("oper.editSuccess")),e.loadData()}).catch(function(t){e.$message.error(t||e.$t("error.networkError"))})}else this.$refs.record.validate(function(t){if(t){var r=s()({},e.record);13===new Date(r.expired).getTime().toString().length?r.expired/=1e3:r.expired=void 0,e.$httpPut("/apps/"+r.app_id,r).then(function(){e.displayDialog=!1,e.$message.success(e.$t("oper.editSuccess")),e.loadData()}).catch(function(t){e.$message.error(t||e.$t("error.networkError"))})}})},showApp:function(e){var t=this;this.oper="view",this.$httpGet("/apps/"+e.app_id).then(function(e){t.displayDialog=!0,t.record=e.data,10===t.record.expired.toString().length&&(t.record.expired=new Date(1e3*t.record.expired)),t.displayDialog=!0}).catch(function(e){t.$message.error(e||t.$t("error.networkError"))})},deleteApp:function(e){var t=this;this.$httpDelete("/apps/"+e.app_id).then(function(){t.loadData(),t.hidePopover()}).catch(function(e){t.$message.error(e||t.$t("error.networkError"))})},handleOperation:function(){var e=this,t=!(arguments.length>0&&void 0!==arguments[0])||arguments[0],r=arguments[1];this.displayDialog=!0,setTimeout(function(){t?(e.oper="new",e.record={app_id:Math.random().toString(16).slice(2),name:"",desc:"",secret:"",expired:"",status:!0}):(e.oper="edit",e.record=s()({},r),e.record.expired=e.record.expired&&10===e.record.expired.toString().length?new Date(1e3*e.record.expired):""),e.$refs.record.resetFields()},10)},hidePopover:function(){var e=this;this.popoverVisible=!0,setTimeout(function(){e.popoverVisible=!1},0)},dateFormat:function(e){try{return 10===e.toString().length?l()(1e3*e,"yyyy-mm-dd"):this.$t("app.expiredText")}catch(e){return this.$t("app.expiredText")}}},created:function(){this.loadData()}},n={render:function(){var e=this,t=e.$createElement,r=e._self._c||t;return r("div",{staticClass:"applications-view"},[r("div",{staticClass:"page-title"},[e._v("\n    "+e._s(e.$t("leftbar.applications"))+"\n    "),r("el-button",{staticClass:"confirm-btn",staticStyle:{float:"right"},attrs:{round:"",plain:"",type:"success",icon:"el-icon-plus",size:"medium",disable:e.$store.state.loading},on:{click:e.handleOperation}},[e._v("\n      "+e._s(e.$t("app.newApp"))+"\n    ")])],1),e._v(" "),r("el-table",{directives:[{name:"loading",rawName:"v-loading",value:e.$store.state.loading,expression:"$store.state.loading"}],attrs:{border:"",data:e.tableData}},[r("el-table-column",{attrs:{prop:"app_id","min-width":"90px",label:e.$t("app.appId")}}),e._v(" "),r("el-table-column",{attrs:{prop:"name","min-width":"100px",label:e.$t("app.name")}}),e._v(" "),r("el-table-column",{attrs:{prop:"expired","min-width":"120px",label:e.$t("app.expired")},scopedSlots:e._u([{key:"default",fn:function(t){return[e._v("\n        "+e._s(e.dateFormat(t.row.expired))+"\n      ")]}}])}),e._v(" "),r("el-table-column",{attrs:{prop:"desc","min-width":"90px",label:e.$t("app.desc")}}),e._v(" "),r("el-table-column",{attrs:{label:e.$t("app.status")},scopedSlots:e._u([{key:"default",fn:function(t){return[r("el-tooltip",{attrs:{content:t.row.status?e.$t("app.enableText"):e.$t("app.disableText"),placement:"left"}},[r("el-switch",{attrs:{"active-text":"","inactive-text":"","active-color":"#13ce66","inactive-color":"#ff4949"},on:{change:function(r){return e.updateApp(!0,t.row)}},model:{value:t.row.status,callback:function(r){e.$set(t.row,"status",r)},expression:"props.row.status"}})],1)]}}])}),e._v(" "),r("el-table-column",{attrs:{width:"180px",label:e.$t("oper.oper")},scopedSlots:e._u([{key:"default",fn:function(t){return[r("el-button",{attrs:{type:"success",size:"mini",plain:""},on:{click:function(r){return e.showApp(t.row)}}},[e._v("\n          "+e._s(e.$t("oper.view"))+"\n        ")]),e._v(" "),r("el-button",{attrs:{type:"success",size:"mini",plain:""},on:{click:function(r){return e.handleOperation(!1,t.row)}}},[e._v("\n          "+e._s(e.$t("oper.edit"))+"\n        ")]),e._v(" "),r("el-popover",{attrs:{placement:"right",trigger:"click",value:e.popoverVisible}},[r("p",[e._v(e._s(e.$t("oper.confirmDelete")))]),e._v(" "),r("div",{staticStyle:{"text-align":"right"}},[r("el-button",{staticClass:"cache-btn",attrs:{size:"mini",type:"text"},on:{click:e.hidePopover}},[e._v("\n              "+e._s(e.$t("oper.cancel"))+"\n            ")]),e._v(" "),r("el-button",{attrs:{size:"mini",type:"success"},on:{click:function(r){return e.deleteApp(t.row)}}},[e._v("\n              "+e._s(e.$t("oper.confirm"))+"\n            ")])],1),e._v(" "),r("el-button",{attrs:{slot:"reference",size:"mini",type:"danger",plain:""},slot:"reference"},[e._v("\n            "+e._s(e.$t("oper.delete"))+"\n          ")])],1)]}}])})],1),e._v(" "),r("el-dialog",{attrs:{width:"view"===e.oper?"660px":"500px",visible:e.displayDialog,title:e.$t("app."+e.oper+"App")},on:{"update:visible":function(t){e.displayDialog=t}},nativeOn:{keyup:function(t){return!t.type.indexOf("key")&&e._k(t.keyCode,"enter",13,t.key,"Enter")?null:e.createApp(t)}}},[r("el-form",{ref:"record",staticClass:"el-form--public app-info",attrs:{size:"medium",rules:"view"===e.oper?{}:e.rules,model:e.record}},[r("el-row",{attrs:{gutter:20}},["view"===e.oper?[r("el-col",{attrs:{span:12}},[r("el-form-item",{attrs:{prop:"app_id",label:e.$t("app.appId")}},[r("el-input",{staticClass:"is-disabled",attrs:{readonly:!0},model:{value:e.record.app_id,callback:function(t){e.$set(e.record,"app_id",t)},expression:"record.app_id"}})],1)],1),e._v(" "),r("el-col",{attrs:{span:12}},[r("el-form-item",{attrs:{label:e.$t("app.secret")}},[r("el-input",{staticClass:"is-disabled",attrs:{readonly:!0},model:{value:e.record.secret,callback:function(t){e.$set(e.record,"secret",t)},expression:"record.secret"}})],1)],1),e._v(" "),r("el-col",{attrs:{span:12}},[r("el-form-item",{attrs:{prop:"name",label:e.$t("app.name")}},[r("el-input",{staticClass:"is-disabled",attrs:{readonly:!0},model:{value:e.record.name,callback:function(t){e.$set(e.record,"name",t)},expression:"record.name"}})],1)],1),e._v(" "),r("el-col",{attrs:{span:12}},[r("el-form-item",{attrs:{prop:"status",label:e.$t("app.status")}},[r("el-select",{staticClass:"el-select--public",attrs:{"popper-class":"el-select--public",disabled:"view"===e.oper},model:{value:e.record.status,callback:function(t){e.$set(e.record,"status",t)},expression:"record.status"}},[r("el-option",{attrs:{label:e.$t("app.enable"),value:!0}}),e._v(" "),r("el-option",{attrs:{label:e.$t("app.disable"),value:!1}})],1)],1)],1),e._v(" "),r("el-col",{attrs:{span:12}},[r("el-form-item",{attrs:{label:e.$t("app.expired")}},[r("el-date-picker",{attrs:{"picker-options":e.pickerDisable,placeholder:e.$t("app.expiredText"),disabled:"view"===e.oper},model:{value:e.record.expired,callback:function(t){e.$set(e.record,"expired",t)},expression:"record.expired"}})],1)],1),e._v(" "),r("el-col",{attrs:{span:12}},[r("el-form-item",{attrs:{prop:"desc",label:e.$t("app.desc")}},[r("el-input",{staticClass:"is-disabled",attrs:{readonly:!0},model:{value:e.record.desc,callback:function(t){e.$set(e.record,"desc",t)},expression:"record.desc"}})],1)],1)]:[r("el-col",{attrs:{span:12}},[r("el-form-item",{attrs:{prop:"app_id",label:e.$t("app.appId")}},[r("el-input",{attrs:{disabled:["view","edit"].includes(e.oper)},model:{value:e.record.app_id,callback:function(t){e.$set(e.record,"app_id",t)},expression:"record.app_id"}})],1)],1),e._v(" "),r("el-col",{attrs:{span:12}},["view"===e.oper?r("el-form-item",{attrs:{label:e.$t("app.secret")}},[r("el-input",{attrs:{disabled:""},model:{value:e.record.secret,callback:function(t){e.$set(e.record,"secret",t)},expression:"record.secret"}})],1):e._e()],1),e._v(" "),r("el-col",{attrs:{span:12}},[r("el-form-item",{attrs:{prop:"name",label:e.$t("app.name")}},[r("el-input",{attrs:{disabled:["view","edit"].includes(e.oper)},model:{value:e.record.name,callback:function(t){e.$set(e.record,"name",t)},expression:"record.name"}})],1)],1),e._v(" "),r("el-col",{attrs:{span:12}}),e._v(" "),r("el-col",{attrs:{span:12}},[r("el-form-item",{attrs:{prop:"status",label:e.$t("app.status")}},[r("el-select",{staticClass:"el-select--public",attrs:{"popper-class":"el-select--public",disabled:"view"===e.oper},model:{value:e.record.status,callback:function(t){e.$set(e.record,"status",t)},expression:"record.status"}},[r("el-option",{attrs:{label:e.$t("app.enable"),value:!0}}),e._v(" "),r("el-option",{attrs:{label:e.$t("app.disable"),value:!1}})],1)],1)],1),e._v(" "),r("el-col",{attrs:{span:12}},[r("el-form-item",{attrs:{label:e.$t("app.expired")}},[r("el-date-picker",{attrs:{"picker-options":e.pickerDisable,placeholder:e.$t("app.expiredText"),disabled:"view"===e.oper},model:{value:e.record.expired,callback:function(t){e.$set(e.record,"expired",t)},expression:"record.expired"}})],1)],1),e._v(" "),r("el-col",{attrs:{span:12}},[r("el-form-item",{attrs:{prop:"desc",label:e.$t("app.desc")}},[r("el-input",{attrs:{disabled:["view"].includes(e.oper)},model:{value:e.record.desc,callback:function(t){e.$set(e.record,"desc",t)},expression:"record.desc"}})],1)],1)]],2)],1),e._v(" "),"view"!==e.oper?r("div",{attrs:{slot:"footer"},slot:"footer"},[r("el-button",{staticClass:"cache-btn",attrs:{type:"text"},on:{click:function(t){e.displayDialog=!1}}},[e._v("\n        "+e._s(e.$t("oper.cancel"))+"\n      ")]),e._v(" "),"edit"===e.oper?r("el-button",{staticClass:"confirm-btn",attrs:{type:"success",loading:e.$store.state.loading,disabled:e.$store.state.loading},on:{click:function(t){return e.updateApp(!1)}}},[e._v("\n        "+e._s(e.$t("oper.save"))+"\n      ")]):e._e(),e._v(" "),"new"===e.oper?r("el-button",{staticClass:"confirm-btn",attrs:{type:"success",loading:e.$store.state.loading,disabled:e.$store.state.loading},on:{click:e.createApp}},[e._v("\n        "+e._s(e.$t("oper.save"))+"\n      ")]):e._e()],1):r("div",{attrs:{slot:"footer"},slot:"footer"},[r("div",{staticClass:"guide-doc"},[e._v("\n        "+e._s(this.$t("app.guide"))+"\n        "),r("a",{attrs:{href:"zh"===e.lang?"https://docs.emqx.io/broker/latest/cn/advanced/http-api.html":"https://docs.emqx.io/broker/latest/en/advanced/http-api.html",target:"_blank"}},[e._v("\n          "+e._s(e.$t("app.docs"))+"\n        ")])])])],1)],1)},staticRenderFns:[]};var c=r("VU/8")(p,n,!1,function(e){r("q13D")},null,null);t.default=c.exports},q13D:function(e,t){}});