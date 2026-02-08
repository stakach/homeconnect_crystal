require "./spec_helper"
require "../src/parser"

describe HomeconnectLocal::Parser do
  it "parses feature mapping and device description" do
    feature_xml = File.read(File.join(__DIR__, "fixtures", "feature_mapping.xml"))
    device_xml  = File.read(File.join(__DIR__, "fixtures", "device_description.xml"))

    dd = HomeconnectLocal::Parser.parse_device_description(device_xml, feature_xml)

    dd.info["brand"].as_s.should eq("Bosch")
    dd.status.size.should eq(1)
    dd.status[0].name.should eq("BSH.Common.Status.OperationState")

    dd.status[0].enum_map.not_nil![1].should eq("On")

    dd.option.size.should eq(1)
    dd.option[0].min.should eq(0.0)
    dd.option[0].max.should eq(3600.0)

    dd.program.size.should eq(1)
    dd.program[0].options.should eq([2])
  end
end
