import { expect, test } from "@playwright/test";
import { defaultComplaintOptions } from "../../src/lib/complaints";

test("searchable complaints support intake, editing, custom entries and clearing on mobile", async ({page}) => {
  await page.setViewportSize({width:390,height:844});
  await page.addInitScript(()=>localStorage.setItem("tent-flow-dev-auth",JSON.stringify({access_token:"token",refresh_token:"refresh",token_type:"bearer",expires_at:Math.floor(Date.now()/1000)+3600,user:{id:"user"}})));
  const snapshot:any={pods:[],visits:[],placements:[],turnovers:[]};
  await page.route("**/rest/v1/rpc/my_races",route=>route.fulfill({json:[{id:"race",name:"Test Race",role:"owner",state:"active"}]}));
  await page.route("**/rest/v1/rpc/available_races",route=>route.fulfill({json:[]}));
  await page.route("**/rest/v1/rpc/my_race_invitations",route=>route.fulfill({json:[]}));
  await page.route("**/rest/v1/rpc/race_complaints",route=>route.fulfill({json:[...defaultComplaintOptions(),{label:"Muscle Cramp",enabled:true}]}));
  await page.route("**/rest/v1/rpc/patient_board",route=>route.fulfill({json:snapshot}));
  const saves:any[]=[];
  await page.route("**/rest/v1/rpc/save_patient",route=>{
    const body=route.request().postDataJSON(); saves.push(body);
    snapshot.visits=[{id:body.p_visit,...body.p_details,revision:saves.length,dispositioned_at:null,medical_started_at:null}];
    return route.fulfill({json:saves.length});
  });
  await page.goto("/");
  await page.getByRole("button",{name:"Open board"}).click();
  await page.getByRole("button",{name:"New Patient",exact:true}).click();
  const dialog=page.getByRole("dialog");
  const picker=dialog.getByRole("combobox",{name:"Chief complaint",exact:true});
  await dialog.getByLabel("Race #",{exact:true}).fill("SEARCH-1");
  await picker.fill("PAIN chest");
  await expect(dialog.getByRole("option",{name:"Chest Pain",exact:true})).toBeVisible();
  await expect(dialog.getByRole("option",{name:"Back Pain",exact:true})).toHaveCount(0);
  expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);
  await page.screenshot({path:"test-results/searchable-complaints-phone.png",fullPage:true});
  await picker.press("ArrowDown"); await picker.press("Enter");
  await expect(picker).toHaveValue("Chest Pain");
  await picker.click();
  await expect(picker).toHaveAttribute("aria-expanded","true");
  await picker.fill("unselected query"); await picker.press("Escape");
  await expect(picker).toHaveValue("Chest Pain");
  await dialog.getByRole("button",{name:"Add",exact:true}).click();
  await expect(dialog).toHaveCount(0);
  expect(saves[0].p_details.complaint).toBe("Chest Pain");

  await page.getByRole("button",{name:"Edit patient SEARCH-1",exact:true}).click();
  await picker.fill("cramp");
  await dialog.getByRole("option",{name:"Muscle Cramp",exact:true}).click();
  await dialog.getByRole("button",{name:"Save",exact:true}).click();
  await expect(dialog).toHaveCount(0);
  expect(saves[1].p_details.complaint).toBe("Muscle Cramp");

  await page.getByRole("button",{name:"Edit patient SEARCH-1",exact:true}).click();
  await picker.fill("zzzz");
  await expect(dialog.getByRole("status")).toContainText("No matching complaints");
  await dialog.getByRole("option",{name:"Other",exact:true}).click();
  await dialog.getByLabel("Other complaint",{exact:true}).fill("Custom symptom");
  await dialog.getByRole("button",{name:"Save",exact:true}).click();
  await expect(dialog).toHaveCount(0);
  expect(saves[2].p_details.complaint).toBe("Custom symptom");

  await page.getByRole("button",{name:"Edit patient SEARCH-1",exact:true}).click();
  await dialog.getByRole("button",{name:"Clear chief complaint"}).click();
  await dialog.getByRole("button",{name:"Save",exact:true}).click();
  await expect(dialog).toHaveCount(0);
  expect(saves[3].p_details.complaint).toBe("");
});
